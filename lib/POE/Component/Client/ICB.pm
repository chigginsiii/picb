package POE::Component::Client::ICB;
#
# client for ICB protocol
# emits events from server input
# state/handler commands
#

use strict;
use POE qw(Component::Client::TCP Filter::ICB);
use Time::HiRes qw(gettimeofday tv_interval);
use Readonly;

##
## CONSTANTS
##

#
# accessors
#
Readonly::Scalar our $ICB_SESSION  => 0;
Readonly::Scalar our $SERVER       => 1;
Readonly::Scalar our $PARAMS       => 2;
Readonly::Scalar our $OPTS         => 3;

#
# protocol bytes for commands/msgs
#
Readonly::Scalar our $DEL       => "\001";  # delimiter
Readonly::Scalar our $M_LOGIN   => 'a';     # login response - c->s fields: user, login, group, pass, login_status; s->c fields: none
Readonly::Scalar our $M_OMSG    => 'b';     # open message - fields: nick, content
Readonly::Scalar our $M_PMSG    => 'c';     # personal message - fields: nick, content
Readonly::Scalar our $M_STATUS  => 'd';     # group status update message - fields: category content
Readonly::Scalar our $M_ERROR   => 'e';     # error message - fields: content
Readonly::Scalar our $M_ALERT   => 'f';     # important announcement - fields: category content
Readonly::Scalar our $M_EXIT    => 'g';     # quit packet from server - fields: none
Readonly::Scalar our $M_COMMAND => 'h';     # send a command from user
Readonly::Scalar our $M_CMDOUT  => 'i';     # output from a command - fields: out type, (fields), msg id (if cmd had one)
Readonly::Scalar our $M_PROTO   => 'j';     # protocol/version information - fields: proto ver, host id, server id
Readonly::Scalar our $M_BEEP    => 'k';     # beeps - fields: nick
Readonly::Scalar our $M_PING    => 'l';     # ping packet from server - fields: msg id (opt)
Readonly::Scalar our $M_PONG    => 'm';     # return for ping packet
Readonly::Scalar our $M_NOOP    => 'n';     # no-op

Readonly::Scalar our $CO_CMDOUT  => 'co';    # generic command output
Readonly::Scalar our $CO_ENDCO   => 'ec';    # end of command output
Readonly::Scalar our $CO_WHOLINE => 'wl';    # who line: mod/nick/idle/[dep]/login/username/hostname/reg-status
Readonly::Scalar our $CO_WHOHEAD => 'wh';    # who header: string
Readonly::Scalar our $CO_WHOGROUP=> 'wg';    # who group: name/topic


# not bothering with gh/ch/c

#
# command handlers:
#
# Readonly::Scalar our 
Readonly::Scalar our $NO_ARG        =>  '_cmd_no_arg'  ;
Readonly::Scalar our $ONE_ARG       =>  '_cmd_one_arg' ;
Readonly::Scalar our $TWO_ARG       =>  '_cmd_two_arg' ;
Readonly::Scalar our $NO_OR_ONE_ARG =>  '_cmd_no_or_one_arg' ;
Readonly::Scalar our $ONE_OR_TWO_ARG=>  '_cmd_one_or_two_arg' ;
Readonly::Scalar our $MULTI_ARG     =>  '_cmd_multi_arg' ;
#


sub new {

    my $class = shift;
    my $self = [
	undef,             ## ICB_SESSION
	undef,             ## SERVER
	{},                ## PARAMS
	{},                ## OPTS
    ];

    bless $self, (ref $class || $class);
    $self->init(@_);
    return $self;

}

sub init {
    my $self = shift;
    my %opts = @_;

    # check for vital init args / configs
    foreach my $opt_key ( qw(
				EventPrefix Alias
				User Nick Name Group Pass GroupStatus
				RemoteHost RemotePort
				Debug Trace Default
			) ) {
	$self->[$OPTS]->{$opt_key} = delete $opts{$opt_key} if defined $opts{$opt_key};
    }
    # NOTE: unknown constructor args will fire error events once we've started the session.
    foreach my $leftover ( keys %opts ) {
	my $value = $opts{$leftover};
	warn ref($self).": unknown constructor param: '$leftover' => '$value'\n";
    }



    #
    # debugging
    #
    $self->[$PARAMS]{uc($_)} = ( $self->[$OPTS]{$_} || 0 ) foreach ( qw(Debug Trace Default) );

    # defaults
    my $alias = $self->[$PARAMS]{Alias} = ( $self->[$OPTS]->{Alias} || 'icb_client' );

    #
    # login defaults, once logged in they populate [$PARAMS]{User Nick Group Pass GroupStatus}
    #
    $self->[$OPTS]->{User}    ||= getlogin();
    $self->[$OPTS]->{Nick}    ||= ($self->[$OPTS]{Name} || 'big_dummy');
    $self->[$OPTS]->{Group}   ||= 'big_dummy';
    $self->[$OPTS]->{Command} ||= 'login';

    #
    # make the script tell us that the default is default.icb.net, bygawd :)
    # these are held in OPTS until the connection, then become [$PARAMS]{(Host Port)}
    #
    die "Missing required arg: RemoteHost" unless $self->[$OPTS]->{RemoteHost};
    $self->[$OPTS]->{RemotePort} ||= '7326';

    # default event prefix:
    $self->[$PARAMS]{EventPrefix} = ( $self->[$OPTS]{EventPrefix} ||  'icb_client_' );

    # map response packets to handlers
    $self->[$PARAMS]->{ResponseHandlers} = {
	'a'  => 'handle_response_login',        # $M_LOGIN
	'b'  => 'handle_response_open_msg',     # $M_OMSG
	'c'  => 'handle_response_private_msg',  # $M_PMSG
	'd'  => 'handle_response_status',       # $M_STATUS
	'e'  => 'handle_response_error',        # $M_ERROR
	'f'  => 'handle_response_alert',        # $M_ALERT
	'g'  => 'handle_response_exit',         # $M_EXIT

	# M_CMDOUT dispatched straight from handle_server_response
	'j'  => 'handle_response_protocol',     # $M_PROTO
	'k'  => 'handle_response_beep',         # $M_BEEP
	'l'  => 'handle_response_ping',         # $M_PING
	'm'  => 'handle_response_pong',         # $M_PONG
	'n'  => 'handle_response_noop',         # $M_NOOP
    };
    $self->[$PARAMS]->{CommandOutputHandlers} = {
	'co' => 'handle_cmdout',             # $CO_CMDOUT
	'ec' => 'handle_cmdout_end',         # $CO_ENDCO
	'wl' => 'handle_cmdout_wholine',     # $CO_WHOLINE
	'wh' => 'handle_cmdout_whohead',     # $CO_WHOHEAD
	'wg' => 'handle_cmdout_whogroup',    # $CO_WHOGROUP
    };

    # create this client session, with object states
    $self->[$ICB_SESSION] = POE::Session->create(
	inline_states => {
	    _start => sub {
		my ($K) = @_[KERNEL];
		$K->alias_set($alias);
	    },
	},
	object_states => [
	    $self => [ qw(
			     _stop
			     register_session send_event
			     handle_connected handle_connect_error handle_disconnected
			     handle_server_input handle_server_error
			     send_packet _cmd_command
		     ) ],

	    $self => [ values %{ $self->[$PARAMS]->{ResponseHandlers} } ],
	    $self => [ values %{ $self->[$PARAMS]->{CommandOutputHandlers} } ],

	    $self => {
		#
		# server commands with their own protocol definitions
		#
		login     => '_cmd_login',
		omsg      => '_cmd_open_message',
		protocol  => '_cmd_protocol',
		ping      => '_cmd_ping',
		pong      => '_cmd_pong',
		noop      => '_cmd_noop',

		# h-commands with interesting arg validation
		# or toggling of internal states, then handed
		# to _cmd_command
		echoback  => '_cmd_echoback',
		nobeep    => '_cmd_nobeep',

		# commands: h => hCommand^AArguments[^AmsgID]
		# these get filtered through the one_arg/two_arg/etc,
		# but then get command-formatted wth _cmd_command

		status    => $ONE_ARG,
		talk      => $ONE_ARG,
		w         => $ONE_ARG,
		notify    => $ONE_ARG,
		name      => $ONE_ARG,
		hush      => $ONE_ARG,
		away      => $NO_OR_ONE_ARG,
		noaway    => $NO_ARG,
		invite    => $ONE_ARG,
		cancel    => $ONE_ARG,
		beep      => $MULTI_ARG,
		boot      => $ONE_OR_TWO_ARG,
		drop      => $TWO_ARG,
		exclude   => $MULTI_ARG,
		group     => $ONE_ARG,
		m         => $TWO_ARG,
		motd      => $NO_ARG,
		news      => $NO_OR_ONE_ARG,
		notify    => $ONE_OR_TWO_ARG,
		pass      => $ONE_ARG,
		s_help    => $NO_ARG,
		shuttime  => $NO_ARG,
		topic     => $MULTI_ARG,
		version   => $NO_ARG,
		w         => $NO_OR_ONE_ARG,
		whereis   => $NO_OR_ONE_ARG,

	    },
	],
	options => {
	    debug   => $self->[$PARAMS]{DEBUG},
	    trace   => $self->[$PARAMS]{TRACE},
	    default => $self->[$PARAMS]{DEFAULT}
	},
	heap => { REGISTERED => [] },
	args => { },
    );

    # create tcp client session, save to self->[$SERVER]
    $self->[$SERVER] = POE::Component::Client::TCP->new(
	Alias         => ref($self->[$SERVER]),
	RemoteAddress => $self->[$OPTS]->{RemoteHost},
	RemotePort    => $self->[$OPTS]->{RemotePort},
	Connected     => sub { $_[KERNEL]->post($alias, 'handle_connected'     => @_[ARG0..$#_] ) },
	ConnectError  => sub { $_[KERNEL]->post($alias, 'handle_connect_error' => @_[ARG0..$#_]) },
	Disconnected  => sub { $_[KERNEL]->post($alias, 'handle_disconnected') },
	ServerInput   => sub { $_[KERNEL]->post($alias, 'handle_server_input'  => @_[ARG0..$#_]) },
	ServerError   => sub { $_[KERNEL]->post($alias, 'handle_server_error'  => @_[ARG0..$#_]) },
	Filter        => ['POE::Filter::ICB' => DEBUG => $self->[$PARAMS]{TRACE} ],
	InlineStates  => {
	    ClientInput => sub { $_[HEAP]->{server}->put($_[ARG0]); },
	},
	SessionParams => [
	    options => {
		debug   => $self->[$PARAMS]{DEBUG},
		trace   => $self->[$PARAMS]{TRACE},
		default => $self->[$PARAMS]{DEFAULT}
	    },
	],
    );

    return;
}

sub debug {
    my ($self,@msgs) = @_;
    return unless $self->[$PARAMS]{DEBUG};
    $self->output_debug('DEBUG', @msgs);
}
sub trace {
    my ($self,@msgs) = @_;
    return unless $self->[$PARAMS]{TRACE};
    $self->output_debug('TRACE', @msgs);
}
sub output_debug {
    my ($self,$type,@msgs) = @_;
    my $sub = (caller(2))[3];
    foreach my $msg ( @msgs ) {
	print STDERR "[$type] $sub => $msg\n";
	if ( ref($msg) ) {
	    print STDERR Data::Dumper::Dumper($msg);
	}
    }
}

sub _stop {
    my ($self,$K,$H) = @_[OBJECT,KERNEL];

    $H->{registered_sessions} = undef;
    # destroy should call this, then eliminate from self
    # kill the tcp client, remove
    $K->call($self->[$SERVER] => 'shutdown');
    $self->[$SERVER] = undef;
    $K->alias_remove($self->[$PARAMS]->{Alias});
    return;

}

#
# register(): another session is letting us know it wants
#             the events we emit
#

sub register_session {
    my ($self,$K,$H,$sender) = @_[OBJECT,KERNEL,HEAP,SENDER];
    $self->debug("registering session: " . $sender->ID() . " (".$sender.")");
    push @{ $H->{ REGISTERED } }, $sender->ID();
    $self->trace("heap now contains " . @{ $H->{ REGISTERED } } . " sessions");
    return;
}
#
# send_event(): sends event to all registered sessions
#
sub send_event {
    my ($self,$K,$H,$event,@args) = @_[OBJECT,KERNEL,HEAP,ARG0..$#_];

    $event = $self->[$PARAMS]{EventPrefix}.$event if defined $self->[$PARAMS]{EventPrefix};
    $self->debug("sending event: $event");

    foreach my $rs ( @{ $H->{REGISTERED} } ) {
	$self->trace("sending event $event to session: " . $rs . " with args: " . join('|', @args) );
	$K->post($rs => $event => @args);
    }
    return;
}

sub handle_connected {
    my ($self,$K,$H,$sock,$r_addr,$r_port) = @_[OBJECT,KERNEL,HEAP,ARG0..$#_];
    $self->[$PARAMS]{Host} = $self->[$PARAMS]{RemoteHost};
    $self->[$PARAMS]{Port} = $self->[$PARAMS]{RemotePort};
    $K->yield('send_event' => 'connected' => $r_addr,$r_port);
}

sub handle_connect_error {
    my ($self,$K,$op,$err,$errmsg) = @_[OBJECT,KERNEL,ARG0,ARG1,ARG2];
    $K->yield('send_event' => 'server_error' => "connect error: operation '$op' failed: '$errmsg' (code:$err)");
}

sub handle_disconnected {
    my ($K,$H) = @_[KERNEL,HEAP];
    $K->yield('send_event' => 'disconnected');
}


##
## HANDLE SERVER INPUT: emit events to registered sessions
##

sub handle_server_input {
    my ($self,$K,$input) = @_[OBJECT,KERNEL,ARG0];
    my $vis_input = $input;
    $vis_input =~ s/\001/\^A/g;
    $self->trace("input: $vis_input");

    my ($proto,$line) = unpack("AA*", $input);
    $self->trace("unpacked: $proto | $line");

    my ($response_handler,$type,$content);

    # figure out what kind of line we're returning
    if ( $proto eq $M_CMDOUT ) {
	($type,$content) = ($line =~ /^([\w]+?)\001(.*)/);
	$response_handler = $self->[$PARAMS]->{CommandOutputHandlers}->{$type};
	$self->trace("CMD OUT: proto '$proto' | type '$type' | handler '$response_handler' | args: $line" );
    } else {
	$response_handler = $self->[$PARAMS]->{ResponseHandlers}->{$proto};
	$content = $line;
	$self->trace("OUT: proto '$proto' | handler '$response_handler' | arg: $line" );
    }

    if ( ! $response_handler ) {
	$K->yield('send_event' => 'error' => "Could not understand protocol byte '$proto'");
    } else {
	$K->yield($response_handler => $content);
    }

    return;
}

sub handle_server_error {
    my ($K,$op,$errcode,$errmsg) = @_[KERNEL,ARG0..ARG2];
    $K->yield('send_event' => 'server_error' => "Operation '$op' failed: '$errmsg' (code:$errcode)");
    return;
}

sub handle_response_login {
    my ($self,$K,@args) = @_[OBJECT,KERNEL,ARG0..$#_];
    $self->[$PARAMS]->{$_} = $self->[$OPTS]->{$_} foreach ( qw(User Nick Group Pass GroupStatus) );
    $K->yield('send_event' => 'login_ok');
    return;
}

sub handle_response_open_msg {
    my ($K,$line) = @_[KERNEL, ARG0];
    my ($nick,$msg) = split($DEL,$line);
    $K->yield('send_event' => 'open_msg' => $nick,$msg );
}

sub handle_response_private_msg {
    my ($K,$line) = @_[KERNEL, ARG0];
    my ($nick,$msg) = split($DEL,$line);
    $K->yield('send_event' => 'private_msg' => $nick, $msg );
}

sub handle_response_status {
    my ($K,$line) = @_[KERNEL, ARG0];
    my ($cat,$msg) = split($DEL,$line);
    $K->yield('send_event' => 'status' => $cat, $msg );
}

sub handle_response_alert {
    my ($K,$line) = @_[KERNEL, ARG0];
    my ($cat,$msg) = split($DEL,$line);
    $K->yield('send_event' => 'alert' => $cat, $msg );
}

sub handle_response_error {
    my ($K,$error) = @_[KERNEL, ARG0];
    $K->yield('send_event' => 'server_error' => $error );
}

sub handle_response_exit {
    my ($K) = @_[KERNEL];
    $K->yield('send_event' => 'exit');
    return;
}

sub handle_response_protocol {
    my ($K,$line) = @_[KERNEL, ARG0];
    my ($proto,$host_id,$server_id) = split(/$DEL/,$line);
    $K->yield('send_event' => 'protocol' => $proto, $host_id, $server_id );
    return;
}

sub handle_response_beep {
    my ($K,$nick) = @_[KERNEL, ARG0];
    $K->yield('send_event' => 'beep' => $nick);
}

sub handle_response_ping {
    my ($K,$msg_id) = @_[KERNEL, ARG0];
    $K->yield('send_event' => 'ping' => $msg_id);
}

sub handle_response_pong {
    my ($S,$K,$msg_id) = @_[SESSION,KERNEL,ARG0];
    # check to see if we got one...
    my $time;
    $time = $K->call($S,'check_pong',$msg_id) if $msg_id;
    $K->yield('send_event' => 'pong' => $msg_id, $time);
}

sub handle_response_noop {
    my ($K,$msg_id) = @_[KERNEL, ARG0];
    $K->yield('send_event' => 'noop' => $msg_id);
}

# send a packet (to the filter) to the server
sub send_packet {
    my ($self,$K,$msg) = @_[OBJECT,KERNEL,ARG0];
    my $msg_l = length($msg);
    if ( $msg_l > 254 ) {
	$K->yield('send_event' => "error" => "Message too long! (length: $msg_l)");
    } else {
	# should this be a postback?
	$K->post(ref($self->[$SERVER]), 'ClientInput', $msg);
    }
    return;
}

sub handle_cmdout {
    my ($K,$line) = @_[KERNEL,ARG0];
    $K->yield('send_event' => 'cmdout' => $CO_CMDOUT, $line);
    return;
}

sub handle_cmdout_end {
    my ($K,$line) = @_[KERNEL,ARG0];
    $K->yield('send_event' => 'cmdout_end' => $CO_ENDCO);
    return;
}

sub handle_cmdout_wholine {
    my ($K,@args) = @_[KERNEL,ARG0..$#_];
    my @out_args = @args[0..2, 4..8];
    $K->yield('send_event' => 'cmdout_wholine' => $CO_WHOLINE, @out_args);
    return;
}

sub handle_cmdout_whohead {
    my ($K,$line) = @_[KERNEL,ARG0];
    $K->yield('send_event' => 'cmdout_whohead' => $CO_WHOHEAD, $line);
    return;
}

sub handle_cmdout_whogroup {
    my ($K,$name,$topic) = @_[KERNEL,ARG0,ARG1];
    $K->yield('send_event' => 'cmdout_whogroup' => $CO_WHOGROUP, $name, $topic);
    return;
}


##
## SERVER COMMANDS
##
#
# specific command dispatchers
#
sub _cmd_login {
    my($self,$K) = @_[OBJECT,KERNEL];

    # ($user,$nick,$group,$pass,$group_stat) should be able to call these from command, right?
    my @args = map { defined $_ ? $_ : '' } @{$self->[$OPTS]}{qw(User Nick Group Command Pass GroupStatus)};

    # login group status spec is optional
    pop @args unless $args[$#args];
    $K->yield('send_packet' => $M_LOGIN.join($DEL,@args));
    return;
}

sub _cmd_open_message {
    my ($K,$msg) = @_[KERNEL,ARG0];
    $K->yield('send_packet' => $M_OMSG.$msg);
    return;
}

sub _cmd_protocol {
    my ($self,$K) = @_[OBJECT,KERNEL];
    $K->yield('send_packet' => $M_PROTO.$self->genMsgID());
    return;
}

sub _cmd_ping {
    my ($self,$K) = @_[OBJECT,KERNEL];
    my $msg_id = $self->genMsgID();
    # register this ping and time, so pong handler can find it
    $K->yield('note_ping'   => $msg_id);
    $K->yield('send_packet' => $M_PING.$msg_id);
    return;
}

sub _cmd_pong {
    my ($K,$msg_id) = @_[KERNEL,ARG0];
    my $packet_string = $M_PONG.($msg_id || '');
    $K->yield('send_packet' => $packet_string);
    return;
}

sub _cmd_noop {
    my ($K) = @_[KERNEL];
    $K->yield('send_packet' => $M_NOOP);
    return;
}

# formatting events use this to send commands
sub _cmd_command {
    my ($self,$K,$cmd,@args) = @_[OBJECT,KERNEL,ARG0,ARG1..$#_];
    my $proto_cmd;
    if ( @args ) {
	$proto_cmd = $M_COMMAND . join($DEL, $cmd, join(' ',@args));
    } else {
	$proto_cmd = $M_COMMAND . $cmd;
    }
    $K->yield('send_packet', $proto_cmd);
}

# sends a command packet with just the command
sub _cmd_no_arg {
    my ($K,$cmd) = @_[KERNEL,STATE];
    $K->yield('_cmd_command' => $cmd);
}

# command plus joins @args into one arg
sub _cmd_one_arg {
    my ($K,$cmd,@args) = @_[KERNEL,STATE,ARG0..$#_];
    $K->yield('_cmd_command' => $cmd, join(' ', @args) );
}

# there should only be two args
sub _cmd_two_arg {
    my ($K,$cmd,@args) = @_[KERNEL,STATE,ARG0..$#_];
    $K->yield('_cmd_command' => $cmd, $args[0], $args[1]);
}

# not more than one arg
sub _cmd_no_or_one_arg {
    my ($K,$cmd,$arg) = @_[KERNEL,STATE,ARG0];
    my @cmd_and_args = $cmd;
    push @cmd_and_args, $arg if $arg;
    $K->yield('_cmd_command' => @cmd_and_args );
}

sub _cmd_one_or_two_arg {
    my ($K,$cmd,@args) = @_[KERNEL,STATE,ARG0..$#_];
    my @cmd_and_args = ($cmd, shift(@args));
    if ( @args ) {
	push @cmd_and_args, join(' ', @args);
    }
    $K->yield('_cmd_command' => @cmd_and_args );
}

# throw 'em all on there
sub _cmd_multi_arg {
    my ($K,$cmd,@args) = @_[KERNEL,STATE,ARG0..$#_];
    $K->yield('_cmd_command' => $cmd, join(' ', @args) );
}

#
# command packets: these are commands that have
# usage requirements, and i was going to do validation,
# but is that really necessary? ICB's error messaging
# tells you all you need to know about why things failed.
#
# the toggles make sense, and i can see adding msg_id's
# to commands that might change our state (/name for example)
#

sub _cmd_echoback {
    my ($S,$K,$cmd,$on_off_arg) = @_[SESSION,KERNEL,STATE,ARG0];
    my $on_off;
    if ( $on_off_arg ) {
	$on_off = $S->{echoback} = $on_off_arg;
    } else {
	$on_off = $S->{echoback} eq 'on' ? 'off' : 'on';
	$S->{echoback} = $on_off;
    }
    $K->yield('_cmd_command' => $cmd, $on_off);
}

sub _cmd_nobeep {
    my ($S,$K,$cmd,$arg) = @_[SESSION,KERNEL,STATE,ARG0];
    my $toggle;
    if ( $arg ) {
	$toggle = $S->{nobeep} = $arg;
    } else {
	$toggle = $S->{nobeep} eq 'on'
	  ? 'verbose'
          : $S->{nobeep} eq 'verbose'
	    ? 'off'
	    : 'on';
	$S->{nobeep} = $toggle;
    }
    $K->yield('_cmd_command' => $cmd, $toggle);
    return;
}

sub _cmd_status {
    my ($K,$cmd,$args) = @_[KERNEL,STATE,ARG0];
    $K->yield('_cmd_command', $cmd, $args);
}

sub _cmd_talk {
    my ($K,$cmd,$args) = @_[KERNEL,STATE,ARG0];
    $K->yield('_cmd_command', $cmd, $args);
}

sub _cmd_who {
    my ($K,$cmd,$args) = @_[KERNEL,STATE,ARG0];
    $K->yield('_cmd_command', $cmd, $args);
}

##
## Util
##
sub genMsgID {
    my ($self) = shift;
    return $self->[$PARAMS]{User}.'|'.time();
}
sub note_ping {
    my ($session,$id) = @_[SESSION,ARG0];
    $session->{ping} = {} unless $session->{ping};
    $session->{ping}->{$id} = [gettimeofday()];
    return;
}
sub check_pong {
    my ($session,$id) = @_[SESSION,ARG0];
    my $retval = undef;
    if ( $session->{ping} && (my $t0 = delete $session->{ping}->{$id}) ) {
	$retval = tv_interval($t0,[gettimeofday])
    }
    return $retval;
}

##
## DESTROY!
##
sub DESTROY {
    my $self = shift;
    $self->[$ICB_SESSION] = undef;
    $self->[$SERVER]      = undef;
}

=pod

constructor args:
-------------------

+-- Client --+
- EventPrefix: icb_client_ => sets the event prefix for all emitted events
- Debug: 0 => debugging output, plus sessions and filter
- Trace: 0 => trace options for child sessions
- Default: 0 => default option for child sessions

+-- CONNECT --+
|- RemoteHost: [required]
|- RemotePort: 7326

+--- LOGIN ---+
|- User:    default = getlogin()
|- Nick:    (big_dummy)      => may also use 'Name', though if both are present in constructor Nick will be preferred
|- Group:   (big_dummy)
|- Command: (login)
|- Pass:    ''
|- GroupStatus: ''

+-- Events --+
|- client emits events to registered sessions:
   |
   |- icb_client_connected: $addr, $port
   |- icb_client_disconnected
   |- icb_client_server_error: $msg
   |- icb_client_error: $msg
   |- icb_client_login_ok
   |- icb_client_open_msg: $from, $msg
   |- icb_client_private_msg: $from, $msg
   |- icb_client_status: $cat, $msg
   |- icb_client_alert:  $cat, $msg
   |- icb_client_exit:
   |- icb_client_proto:$proto,$host_id,$server_id
   |- icb_client_beep: $nick
   |- icb_client_ping: $msg_id
   |- icb_client_pong: $msg_id, $seconds_in_thousandths
   |- icb_client_cmdout: $type, @args
      |
      |- type args:
         |
         |- 'co', $line
         |- 'ec'
         |- 'wl': mod, nick, idle (sec), undef, login (unixtime), username, host, registration status
         |- 'wh': $line
         |- 'wg': name, topic


client states:
==========================

_start
_stop

register_session
send_event

handle_connected
handle_connect_error
handle_disconnected
handle_server_input
handle_server_error
send_packet

_cmd_command

### THESE NEED ARGS!
login:  so far it only logs in using constructor params, need to make it take overriding args
omsg  => $message
protocol
ping: msgID
pong: msgID
noop

away [$msg]
invite [-q] [-r] [-n name | -s site]
cancel [-q] [-n name | -s site]
echoback [on | off]
hush [$nick]
name $nick
nobeep [on|off|verbose]
status (too many to list on one line)
talk (needs explanation of controlled group)
w [.|@nick|group]
noaway
beep nick [nick [nick...]]
boot nick [msg]
drop nick password
exclude nick msg
group group
m nick msg
motd
news [id]
notify nick
pass password
s_help
shuttime
topic topic
version
whereis nick

=cut

1;
