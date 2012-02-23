#!/usr/bin/perl

#
# ICB client: uses POE::Component::Client::TCP and Term::Visual to provide an ICB client
#
# Portions of this client stolen outright from Net::ICB by John Vinopal (http://search.cpan.org/~jmv/Net-ICB-1.62/ICB.pm)
#

use strict;
use lib qw(lib);

use POE qw(Component::Client::TCP);
use POE::Filter::ICB;
use Term::ChatScreen;

use Getopt::Long;
use DateTime;
use List::Util;
use List::MoreUtils;
use File::Basename;
use Config::Simple;

#
# Config
#

# Protocol definitions: all nice cleartext.

our $DEL         = "\001";  # Packet argument delimiter.

# from server
our $M_LOGINOK   = 'a';     # login response - fields: none
our $M_OMSG      = 'b';     # open message - fields: nick, content
our $M_PMSG      = 'c';     # personal message - fields: nick, content
our $M_STATUS    = 'd';     # group status update message - fields: category content
our $M_ERROR     = 'e';     # error message - fields: content
our $M_ALERT     = 'f';     # important announcement - fields: category content
our $M_EXIT      = 'g';     # quit packet from server - fields: none
our $M_COMMAND   = 'h';     # send a command from user
our $M_CMDOUT    = 'i';     # output from a command - fields: out type, (fields), msg id (if cmd had one)
our $M_PROTO     = 'j';     # protocol/version information - fields: proto ver, host id, server id
our $M_BEEP      = 'k';     # beeps - fields: nick
our $M_PING      = 'l';     # ping packet from server - fields: msg id (opt)
our $M_PONG      = 'm';     # return for ping packet
our $M_NOOP      = 'n';     # no-op

# from client
our $M_LOGIN     = 'a';     # alogin packet
our $M_OPEN      = 'b';     # open msg to group
our $M_PERSONAL  = 'c';     # personal message

# Default connection values.
# (evolve.icb.net, empire.icb.net, cjnetworks.icb.net, swcp.icb.net)
our $DEF_HOST= "default.icb.net";
our $DEF_PORT= 7326;
our $DEF_GROUP= "testpicb";
our $LOGIN_CMD= "login";# cmds are only "login" and "w"
our $DEF_CMD= "w";# cmds are only "login" and "w"
our $DEF_USER= eval { getlogin() };
our $DEF_TIMEZONE = 'America/New_York';

#
# Options
#
my ($opt_nick, $opt_host, $opt_port, $opt_group, $opt_pass, $opt_echo, $opt_debug, $opt_help);

GetOptions(
    'nick|n:s'     => \$opt_nick,
    'host|h:s'     => \$opt_host,
    'port|p:s'     => \$opt_port,
    'group|g:s'    => \$opt_group,
    'pass|p:s'     => \$opt_pass,

    'echoback|e:i' => \$opt_echo,
    'debug|d'      => \$opt_debug,
    'help|h'       => \$opt_help,
);

my $prog = File::Basename::basename($0);
my $USAGE = qq{

USAGE: $prog --nick [nick] [--host [host]] [--port [port]] [--group [group]] [--pass [password]]

nick |n         your nickname
host |h         defaults to default.icb.net
port |p         defaults to 7326
group|g         defaults to '1'
pass |p         your registered nick pw

help |h         print this message and exit

Once connected, type /help at the prompt for client help info,
and /s_help for the server help message.

};

my $config_file = ( $ENV{HOME} ? $ENV{HOME} : '.' ) . "/.picbrc";
if ( ! -f $config_file ) {
    create_default_rc($config_file);
}
my $config = Config::Simple->new($config_file) || die "Could not read config file ($config_file): $!";

if ( $opt_help ) {
    print $USAGE;
    exit(0);
} elsif ( !$opt_nick ) {
    die "Must provide nick!\n$USAGE";
} elsif ( !$DEF_USER ) {
    die "Unable to determine logged-in user!";
}

# XXX: put in help/USAGE here...

#
# Run it!
#

my $connect_host = $opt_host || $config->param("connect.host")  || $DEF_HOST;
my $connect_port = $opt_port || $config->param('connect.port') || $DEF_PORT;

POE::Component::Client::TCP->new(
    RemoteAddress => $connect_host,
    RemotePort    => $connect_port,
    Started       => sub { @{$_[HEAP]}{'config','config_file'} = ($config,$config_file) },
    Connected     => \&setup_client,
    Disconnected  => \&shutdown_client,
    ServerInput   => \&handle_server_input,
    ServerError   => \&handle_server_error,
    Filter        => ['POE::Filter::ICB'],
    InlineStates  => {

      # setup
      setup_terminal      => \&setup_terminal,
      setup_user_commands => \&setup_user_commands,
      setup_session       => \&setup_session_options,

      # handle client input
      user_input       => \&handle_user_input,
      user_command     => \&handle_user_command,
      debug            => \&handle_debug,
      warning          => \&handle_warning,
      history          => \&handle_history,

      # handle client commands
      display_help      => \&display_help,
      reload_palette    => \&reload_palette,
      replay            => \&replay,

      # handle server input
      login            => \&handle_login,
      server_response  => \&handle_server_response,
      pong             => \&handle_pong,

      # util
      send_icb_packet      => \&send_icb_packet,
      add_to_pm_nicks      => \&add_to_pm_nicks,
      remove_from_pm_nicks => \&remove_from_pm_nicks,
    },
    SessionParams => [ options => { default => 0, debug => 0, trace => 0 } ],

);

POE::Kernel->run();
exit();

#
# SETUP HANDLERs
#

# client's connected!
sub setup_client {
    my ($k,$h,$s) = @_[KERNEL,HEAP,SESSION];

    # login options
    $h->{user}  =  $DEF_USER,
    $h->{nick}  =  $opt_nick  || $h->{config}->param("connect.nick")  || $DEF_USER,
    $h->{host}  =  $connect_host,
    $h->{port}  =  $connect_port,
    $h->{group} =  $opt_group || $h->{config}->param("connect.group") || $DEF_GROUP,


    # options set by setup_session_options after login
    $h->{so_echoback} = defined($opt_echo)
      ? $opt_echo
      : $h->{config}->param('options.echoback')
        ? $h->{config}->param('options.echoback')
	: 1;

    # holds list of nicks who've private messaged for tab completion
    $h->{pmsg_nicks}    = [];       # array of nicks we've pm'd or have pm'd us
    $h->{cur_pmsg_nick} = 0; # index of the current auto-complete

    $k->call($s,'setup_user_commands');
    $k->call($s,'setup_terminal');
    $k->yield('login');
    return 1;
}

# table of user input commands and their formats for forming packets
sub setup_user_commands {
  my ($h) = @_[HEAP];

  $h->{s_cmd}       =  {
    away          => sub {format_cmd('away',join(' ',@_))},
    noaway        => sub {format_cmd('noaway',join(' ',@_))},
    beep          => sub {format_cmd('beep',@_)},
    boot          => sub { my @cmd_args = shift;                        # this is the nick
			   if ( @_ ) { push @cmd_args, join(' ', @_); } #  this is the taunting msg
			   format_cmd('boot', @cmd_args);
			 },
    cancel        => sub {format_cmd('cancel',@_)},
    drop          => sub {format_cmd('drop', $_[0])},
    echoback      => sub {format_cmd('echoback',$_[0])},
    nobeep        => sub {format_cmd('nobeep',$_[0])},
    exclude       => sub {format_cmd('exclude',shift,join(' ', @_))},
    g             => sub {format_cmd('g',$_[0])},
    invite        => sub {format_cmd('invite',@_)},
    m             => sub {format_cmd('m',join(' ',@_))},
    motd          => sub {format_cmd('motd')},
    name          => sub {format_cmd('name',$_[0])},
    news          => sub {format_cmd('news',@_)},
    notify        => sub {format_cmd('notify',@_)},
    pass          => sub {format_cmd('pass',$_[0])},
    s_help        => sub {format_cmd('s_help')},
    shuttime      => sub {format_cmd('shuttime')},
    status        => sub {format_cmd('status',join(' ',@_))}, # vsi; pmr, clnq, # N, b N, idlebootmsg, im N, name NEW
    topic         => sub {format_cmd('topic',join(' ',@_))},
    v             => sub {format_cmd('v')},
    w             => sub {format_cmd('w',$_[0])},
    whereis       => sub {format_cmd('whereis',$_[0])},
    hush          => sub {format_cmd('hush',@_)},
    talk          => sub {format_cmd('talk',@_)},
  };

  $h->{s_cmd_alias} = {
    who   => 'w',
    group => 'g',
    stat  => 'status',
    nick  => 'name',
    n     => 'name',
    quit  => 'shutdown',
    exit  => 'shutdown',
    q     => 'shutdown',
  };

  $h->{c_cmd} = {
    help           => 'display_help',
    shutdown       => 'shutdown',
    reload_palette => 'reload_palette',
    rlp            => 'reload_palette',
    d              => 'replay',
    replay         => 'replay',
   };

}

# helper for formatting commands
sub format_cmd {
  my ($cmd,@args) = @_;
  return $M_COMMAND . join($DEL,$cmd,@args);
}

# set up the terminal UI
sub setup_terminal {
  my ($k,$h) = @_[KERNEL,HEAP];

  my $vt = Term::ChatScreen->new(
    Alias => 'vterm',
    TabComplete => sub {

      my ($left,$right) = @_;

      # the mission here is to return one and only one nick
      return unless ( $h->{pmsg_nicks} && @{$h->{pmsg_nicks}} );

      my $whole = $left.$right;
      $whole =~ s/^\/m\s*//;
      $whole =~ s/^(\S+).*/$1/;

      my ($retval);
      if ( ! $whole )
      {
	$h->{cur_pmsg_nick} = 0 unless $h->{pmsg_nicks}->[$h->{cur_pmsg_nick}];
	$retval = $h->{pmsg_nicks}->[$h->{cur_pmsg_nick}];
      }
      else
      {

	# if we already had the whole thing, offer the next one
	my $i = List::MoreUtils::firstidx { $whole eq $_ } @{$h->{pmsg_nicks}};
	if ( $i != -1 )
	{
	  $h->{cur_pmsg_nick} = $i + 1;
	  $h->{cur_pmsg_nick} = 0 unless $h->{pmsg_nicks}->[$h->{cur_pmsg_nick}];
	  $retval = $h->{pmsg_nicks}->[$h->{cur_pmsg_nick}];
	}

	# try for partial completion
	if ( ! $retval )
	{
	  $i = List::MoreUtils::firstidx { $_ =~ m|\Q$whole\E.+| } @{$h->{pmsg_nicks}};
	  if ( $i != -1 )
	  {
	    $h->{cur_pmsg_nick} = $i;
	    $retval = $h->{pmsg_nicks}->[$h->{cur_pmsg_nick}];
	  }
	}

	if ( ! $retval ) {
	  # nothin, cycle to the next name on the list
	  $h->{cur_pmsg_nick} += 1;
	  $h->{cur_pmsg_nick} = 0 unless $h->{pmsg_nicks}->[$h->{cur_pmsg_nick}];
	  $retval = $h->{pmsg_nicks}->[$h->{cur_pmsg_nick}];
	}
      }
      return $retval ? "/m $retval " : '';

    },
   );

  # tell term to send input to our handler
  $k->post('vterm' => 'send_user_input' => 'user_input');

  #    $vt->bind('Up'   => 'history',
  #              'Down' => 'history');

  #
  # XXX COLOR: this needs to load from an rc file
  #
  my %palette = %{ $h->{config}->get_block('colors') };
  $vt->debug(\%palette);
  $vt->set_palette( %palette );

  $h->{vt} = $vt;

  # make this easier for later:
  $h->{winprint} = sub {
      $vt->print( @_ );
  };

  # let's git it on
  $h->{winprint}->(
    "POE-ICB Client 0.2",
    "Login: $h->{host} $h->{port} u:$h->{user} n:$h->{nick} g:$h->{group}"
   );

  $vt->set_title_text(   "  POE ICB 0.2  |  $h->{host}");
  $vt->set_status_format("  [% nick %]  |  [% group %]");
  $vt->set_status_fields( nick => $h->{nick},group =>  $h->{group}, host => $h->{host} );
  $vt->update_status();

}

sub setup_session_options {
    my ($k,$h) = @_[KERNEL,HEAP];

    # echoback:
    if ( $h->{so_echoback} ) {
	$k->yield('send_icb_packet', $M_COMMAND."echoback${DEL}on");
    }
}

#
# SERVER INPUT
#

# defined for TCP client ServerInput config
sub handle_server_input {
    my ($k,$h,$input) = @_[KERNEL,HEAP,ARG0];


    $h->{vt}->debug("input: $input");
    my ($proto,$msg) = unpack("AA*", $input);
    $h->{vt}->debug("proto: $proto, msg:$msg");

    $k->yield('server_response' => $proto,$msg);
    $h->{vt}->debug("leaving");
    return;
}

# defined for TCP client ServerError config
sub handle_server_error {
    my ($h,$k,$op,$code,$msg) = @_[HEAP,KERNEL,ARG0,ARG1,ARG2];
    $k->yield('debug' => "Exception: Operation '$op' failed with code '$code' and msg '$msg'");
}

sub handle_login {
    my ($k,$h) = @_[KERNEL,HEAP];
    my $packet = join($DEL, ($h->{user}, $h->{nick}, $h->{group}, $LOGIN_CMD, $h->{pass}) );
    $k->yield('send_icb_packet' => $M_LOGIN.$packet);
}

#
# XXX:need a similar table as user_commands in heap
#
sub handle_server_response {
    my ($k,$h,$proto,$msg) = @_[KERNEL,HEAP,ARG0,ARG1];
    $h->{vt}->debug("Entering: proto:'$proto', msg:'$msg'");

    my $out = "proto '$proto' has no response handler! here's the message: $msg";
    my ($type,$cmd_out);

    if ( $proto eq $M_LOGINOK ) {
        $out = "\0(msg_bkt)[\0(msg_label)LOGIN\0(msg_bkt)]\0(msg)Login Successful!\0(ncolor)";
	$k->yield('setup_session');
    }
    elsif ( $proto eq $M_OMSG ) {
        my ($sender,$msg) = split($DEL,$msg);
        $out = "\0(o_bkt)".'<'."\0(o_nick)"."$sender"."\0(o_bkt)".">"." \0(o_msg)$msg";
    }
    elsif ( $proto eq $M_PMSG ) {
        my ($sender,$msg) = split($DEL,$msg);
        $out = "\0(p_bkt)".'<*'."\0(p_nick)"."$sender"."\0(p_bkt)"."*>"."\0(p_msg) $msg";
	$k->yield('add_to_pm_nicks' => $sender);
    }
    elsif ( $proto eq $M_STATUS ) {
        my ($cat,$status) = split($DEL,$msg);
        $out = "\0(msg_bkt)[\0(msg_label)$cat\0(msg_bkt)]\0(msg) $status\0(ncolor)";
    }
    elsif ( $proto eq $M_ERROR ) {
        $out = "\0(err_bkt)[\0(err_label)ERROR\0(err_bkt)] \0(err_msg)$msg\0(ncolor)";
	if ( $msg =~ /^\s*(\S+)\s+not signed on/ ) {
	    my $nick = $1;
	    $k->yield("remove_from_pm_nicks" => $nick);
	}
    }
    elsif ( $proto eq $M_ALERT ) {
        my ($cat,$alert) = split($DEL,$msg);
        $out = "\0(alert_bkt)[\0(alert_label)$cat\0(alert_bkt)] \0(alert_msg)$alert\0(ncolor)";
    }
    elsif ( $proto eq $M_EXIT ) {
        $out = "\0(msg_bkt)[\0(msg_label)EXIT\0(msg_bkt)]\0(msg) Goodbye!\0(ncolor)";
	$h->{winprint}->($out);
	$k->yield('shutdown');
	return;
    }
    elsif ( $proto eq $M_PROTO ) {
        my ($prot,$host,$server) = split($DEL,$msg);
        $out = "\0(msg_bkt)[\0(msg_label)ICB Server\0(msg_bkt)]\0(msg) $host running $server";
    }
    elsif ( $proto eq $M_BEEP ) {
        $out ="\0(msg_bkt)[\0(msg_label)BEEP!\0(msg_bkt)]\0(msg) you were beeped by $msg";
    }
    elsif ( $proto eq $M_PING ) {
        $k->yield('pong',$msg);
        $out = "\0(msg_bkt)[\0(msg_label)PONG\0(msg_bkt)]\0(msg) pong for $msg";
    }
    elsif ( $proto eq $M_CMDOUT ) {

        if ( $msg =~ /^(.*?)\001(.*)/ ) {
            ($type,$cmd_out) = ($1,$2);
        } elsif ( $msg =~ /^([a-zA-Z]+)/ ) {
            $type = $1;
        }
	$h->{vt}->debug("Command out: type:'$type' cmd_out:'$cmd_out'");

        if ( $type eq 'co' ) {
            $out = "\0(co)$cmd_out\0(ncolor)";
        }

        elsif ( $type eq 'ec' ) {
            $out = "\0(msg)[EC cmd_out]\0(co) $cmd_out\0(ncolor)";
        }

        elsif ( $type eq 'wl' ) {
            my($mod,$nick,$idle,undef,$loggedin,$user,$host,$regd) = split($DEL,$cmd_out);
            $out = sprintf(
		"  \0(wl_nick)%1s%-16s \0(wl_time)%-9s %-15s \0(wl_user)%s\0(ncolor)",
		($mod eq 'm' ?  '*' : ''),
		$nick,
		seconds_to_dhms($idle) || '-',
		unixtime_to_date($loggedin),
		join('',$user,'@',$host,"($regd)")
	    );
        }
        elsif ($type eq 'wh') {
            $out = sprintf("\n  \0(wh)%1s%-16s %-9s %-15s %-s\0(ncolor)\n", '', 'Nick', 'Idle', 'Sign-on', 'Account');
        }
        elsif ($type eq 'wg') {
            $out = "\0(wg)[wg cmd_out]\0(co) $cmd_out\0(ncolor)";
        }
    }

    if ( $h->{debug} ) {
        $h->{winprint}->("$proto".($type ? "($type)" : '').": $out");
    } else {
        $h->{winprint}->($out);
    }
    return;
}

# these help render server responses above
sub seconds_to_dhms {
    my $seconds = shift;

    my $t = '';
    if ( $seconds ) {
      my $mu = 60;
      my $hu = 60 * 60;
      my $du = 24 * 60 * 60;
      # return (1d)(3h)(5m)
      if ( $seconds > $du ) {
	my $days = int($seconds / $du);
	$seconds = $seconds - ( $days * $du );
	$t .= $days."d";
      }
      if ( $seconds > $hu ) {
	my $hrs = int($seconds / $hu);
	$seconds = $seconds - ( $hrs * $hu );
	$t .= $hrs."h";
      }
      if ( $seconds > $mu ) {
	my $min = int($seconds / $mu);
	$seconds = $seconds - ( $min * $mu );
	$t .= $min."m";
      }
      $t ||= '-'
    }
    return $t;
}
sub unixtime_to_date {
    my $unixtime = shift;
    return '[n/a]' unless $unixtime;
    # Feb 12 12:34p
    my $date = DateTime->from_epoch(epoch => $unixtime)->clone()->set_time_zone($DEF_TIMEZONE)->strftime("%b %e %l:%M%P");
    $date =~ s/  / /g;
    return $date;
}

sub handle_pong {
    my ($k,$h,$id) = @_[KERNEL,HEAP,ARG0];
    $k->yield(send_icb_packet => $M_PONG.$id);
    return;
}

#
#  CLIENT INPUT HANDLERS
#

sub handle_user_input {
    my ($k,$h,$input,$exception) = @_[KERNEL,HEAP,ARG0,ARG1];

    # exception!
    if ( defined($exception) ) {
        $h->{winprint}->("\0(err_bkt)[\0(err_label)CLIENT EXCEPTION\0(err_bkt)]\0(err_msg) Caught an exception: $exception\0(ncolor)");
        $k->yield('shutdown');
        return;
    }

    # no? good. how about input?
    if ( defined($input) ) {

      # could be a user command or server command
      if ( $input =~ m|^\/(.*)| ) {
	my $cmd = $1;
	my @args;
	if ( $cmd =~ /(\w+)\s+(.*)/ ) {
	  $cmd = $1;
	  @args = split(/\s+/, $2);
	}
	$k->yield('user_command' => $cmd, @args);
	return;
      }

      # nope, just an open message
      if ( $input ) {
	$k->yield(send_icb_packet => $M_OPEN.$input);
      } else {
	$h->{winprint}->("");
      }
      return;
    }

    # shouldn't be here, shut down
    $k->yield('shutdown');

}

sub handle_user_command {
  my ($k,$h,$cmd,@args) = @_[KERNEL,HEAP,ARG0..$#_];
  return unless $cmd;

  my $msg = '';
  my $echo;
  # is this an alias?
  if ( my $al = $h->{s_cmd_alias}->{$cmd} ) {
    $cmd = $al;
  }

  # command is in the table, format it!
  if ( $h->{s_cmd}->{$cmd} ) {
    $msg = $h->{s_cmd}->{$cmd}->(@args);
  }

  # client commands
  if ( $h->{c_cmd}->{$cmd} ) {
    $k->yield( $h->{c_cmd}->{$cmd} );
    return;
  }

  # special cases / side effects

  # priv msg: add sender to pm nicks
  if ( $cmd eq 'm' ) {
    my $rcpt = $args[0];
    my $content = join(' ', @args[1.. $#args]);
    $h->{winprint}->("\0(ep_bkt)<*\0(ep_nick)to $rcpt\0(ep_bkt)*>\0(ep_msg) $content\0(ncolor)");
    $k->yield('add_to_pm_nicks', $rcpt);
  }

  # changing nick: keep track or bail
  if ( $cmd eq 'name' ) {
    if ( @args ) {
      $h->{nick} = $args[0];
      $h->{vt}->set_status_fields( nick => $h->{nick} );
      $h->{vt}->update_status();
    } else {
      undef($msg);
      $echo = "ERROR: gotta provide a nick to change to";
    }
  }

  if ( $cmd eq 'g' ) {
      if ( @args ) {
	  $h->{group} = $args[0];
	  $h->{vt}->set_status_fields( group => $h->{group} );
	  $h->{vt}->update_status();
      } else {
	  $echo = "ERROR: gotta provide a group to join";
      }
  }

  # if we have no $msg by this point, and no $echo...
  if ( !$msg && !$echo ) {
    $echo = "I don't understand the command '$cmd' (args: '" . join(' ', @args) . '\')';
  }

  if ($msg) {
    $k->yield('send_icb_packet' => $msg);
  }
  $h->{winprint}->($echo) if $echo;

  return;
}

sub shutdown_client {
    my ($h) = @_[HEAP];
    $h->{winprint}->( "Shutting down!" );
    delete $h->{winprint};
    $h->{vt}->delete_window($h->{window_id});
    $h->{vt}->shutdown;
    return;
}

sub handle_history {
    my ($k,$h,$key,$win) = @_[KERNEL,HEAP,ARG0,ARG2];
    $h->{vt}->command_history($win, ( $key eq 'KEY_UP' ? 1 : 2 ));
}

sub handle_debug {
    my ($h,$msg) = @_[HEAP,ARG0];
    # log to chatterm.log if it's runnin'
    $h->{vt}->debug($msg);
    # also print to STDERR
    print STDERR $msg;
}

sub handle_warning {
    my ($h,$msg) = @_[HEAP,ARG0];
    $h->{winprint}->("[WARNING]: $msg");
}


#
# CLIENT DISPLAY HANDLERS
#

sub replay {
    my ($h,$k,$num_lines) = @_;
    my $term = $h->{vt};

    $term->replay_buffer($num_lines);
}

sub reload_palette {
    my ($h) = @_[HEAP];
    # reload config file
    $h->{vt}->debug("rereading config file ($h->{config_file})");
    $h->{config} = Config::Simple->new($h->{config_file});
    my %palette = %{ $h->{config}->get_block('colors') };
    $h->{vt}->debug(\%palette);
    $h->{vt}->set_palette(%palette);
    $h->{vt}->refresh_screen();
}

sub display_help {
  my ($h) = @_[HEAP];
  my $help = q{\0(help)

 (command aliases listed with command)

 GET SOME HELP
 ---------------------------------------------------------------------
 /help                      display this screen
 /s_help                    server help

 GET IN A GROUP
 ---------------------------------------------------------------------
 /group|g [group]           join group [group]
 /name|n [new nick]         change nick
 /who|w                     list all users on server by group
 /who|w .                   list users in current group
 /who|w @[nick]             list users in group that [nick] is in
 /whereis [nick]            list user details

 GET TO TALKIN'
 ---------------------------------------------------------------------
 /beep [nick [nick..]]      send one or more people beeps
 /m [nick] [msg]            send private message
 /exclude [nick] [msg]      send open msg to everyone but [nick]
 /invite [nick]             invite [nick] to group
 /cancel                    removes from invite list (see /s_help for options)

 OH YEAH, MODERATE DAT CHANNEL
 -------------------------------------------------------------------------------
 /topic                     set group's topic
 /status                    list group status, set group attributes
                            ("/status ?" for attributes)
 /pass [nick]               pass moderatorship
 /boot [nick] [taunt]       kick the sumbitch out the channel
 /talk                      sets who can talk on a controlled group
                            (/s_help for more, '/status ?' for more
                            on controlled groups)

 WHAT YOU WANT, WHEN YOU WANT IT
 ---------------------------------------------------------------------
 /name|n|nick [new nick]    change your name
 /echoback [on|off]         see your own messages
 /notify [nick]             get notified when [nick] in on
 /away [msg]                sets away status/msg
 /noaway                    unsets away
 /shush|hush                block messages (see /s_help)
 /nobeep [off|on|verbose]   don't allow beeps
 /drop [nick]               drop someone using your registered nick

 PRETTY COLORS
 ---------------------------------------------------------------------
 /reload_palette|rlp        reload palette from ini file

 ASK A SERVER
 ---------------------------------------------------------------------
 /v                         version
 /motd                      MotD!
 /news                      news (can provide optional message #)
 /shuttime                  when the server will shutdown

 DIE! DIE! DIE!
 ---------------------------------------------------------------------
 /shutdown|quit|q|bye       all done!

};

  $h->{winprint}->("\0(help)$help\0(ncolor)");
  return;
}

#
# OTHER HANDLERS / UTILS
#

sub send_icb_packet {
  my ($k,$h,$msg) = @_[KERNEL,HEAP,ARG0];

  # XXX: or this would be a good place to do some mid-sentence
  #      splitting and splicing to make multiple packets...
  if ( length($msg) > 253 ) {
    $k->yield('warning' => 'message is too large!');
    return;
  }
  $h->{server}->put("$msg\0");
}

sub add_to_pm_nicks {
  my ($h,$nick) = @_[HEAP,ARG0];
  return if ! $nick;
  if ( ! List::Util::first { $_ eq $nick } @{ $h->{pmsg_nicks} } ) {
    push @{ $h->{pmsg_nicks} }, $nick;
  }
}

sub remove_from_pm_nicks {
  my ($h,$nick) = @_[HEAP,ARG0];
  return if ! $nick;
  my $i = List::MoreUtils::firstidx { $_ eq $nick } @{ $h->{pmsg_nicks} };
  if ( $i != -1 ) {
    my $removed = splice( @{$h->{pmsg_nicks}}, $i, 1 );
  }
}


#
# DEFAULT INI FILE:
#
sub create_default_rc {
    my $filename = shift;
    open(FH,"> $filename") || die "Could not open $filename for writing: $!";
    print FH <<HERE;
[connect]
host  = default.icb.net
port  = 7326
group = def_group
nick  = def_nick

[options]
echoback = on

[colors]
# ChatTerm console colors
stderr_bullet = "bright white on red"
stderr_text   = "bright yellow on black"
ncolor        = "white on black"
statcolor     = "green on black"
st_frames     = "bright yellow on blue"
st_values     = "bright white on blue"	

# open msg coming in
o_bkt   = 'bright yellow'
o_nick  = 'bright red'
o_msg   = 'bright white'
# open msg echoback
eo_bkt  = 'bright yellow'
eo_nick = 'bright red'
eo_msg  = 'bright white'

# pvt msg in
p_bkt   = 'cyan'
p_nick  = 'bright cyan'
p_msg   = 'bright cyan'
# pvt msg echoback
ep_bkt  = 'cyan'
ep_nick = 'bright cyan'
ep_msg  = 'bright cyan'

# err msgs from server
err_bkt   = 'red'
err_label = 'bold red'
err_msg   = 'bold yellow'

# alert msgs from server
alert_bkt   = 'yellow'
alert_label = 'bold yellow'
alert_msg   = 'bold yellow'

# reg msgs
msg_bkt   = 'bold cyan'
msg_label = 'bold green'
msg       = 'bold green'

# command response
co      = 'bright green'
wl      = 'green'
wl_nick = 'bright magenta'
wl_time = 'magenta'
wl_user = 'magenta'
wg      = 'bright green'
wh      = 'bright yellow'

# help!
help  = 'cyan'
HERE
    close(FH);
    return;
}
