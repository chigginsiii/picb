package Term::ChatScreen;

use strict;
use Curses;
use POE qw(Wheel::Curses Wheel::ReadWrite Filter::Line Driver::SysRW);

use Carp qw(croak);
use Term::ReadKey qw(GetTerminalSize);
use List::Util qw(sum);
use Data::Dumper;
use Symbol qw(gensym);

$|++;

#
# $self indexes
#
sub ALIAS          () { 0 }
sub SESSION        () { 1 }  # POE session
sub GEOMETRY       () { 2 }  # TitleHeight, StatusHeight, EditHeight
sub PALETTE        () { 3 }  # this is where we keep the color profiles
sub PAL_NUM_SEQ    () { 4 }  # this is where we keep the color profiles
sub WIN_OUT        () { 5 }  # array of output windows, one per group/channel/pm
sub WIN_OUT_CUR    () { 6 }  # ref to current output window
sub WIN_TITLE      () { 7 }  # title line
sub WIN_STATUS     () { 8 }  # status line under current output window
sub WIN_EDIT       () { 9 }  # input buffer
sub INIT_OPTS      () { 10 } # init options
sub TAB_COMPLETE   () { 11 } # tab completion callback
#
# palette indexes
#
sub PAL_PAIR       () { 0 }   # Index of the COLOR_PAIR in the palette.
sub PAL_NUMBER     () { 1 }   # Index of the color number in the palette.
sub PAL_DESC       () { 2 }   # Text description of the color.

#
# debug stuff
#
sub DEBUG_FLAG () {0}
sub DEBUG_FILE () {'./chatscreen.log'}
sub TRACE_FLAG () {0}

sub debug {
    my ($self,@messages)= @_;
    if ( DEBUG_FLAG ) {
	my $sub = (caller(1))[3];
	$self->log_to_debug_file($sub,@messages);
    }
}

sub trace {
    my ($self,@messages)= @_;
    if ( TRACE_FLAG ) {
	my $sub = (caller(1))[3];
	$self->log_to_debug_file($sub, @messages);
    }
}

sub log_to_debug_file {
    my ($self, $sub, @messages) = @_;

    foreach my $message ( @messages ) {
	if ( ref($message) ) {
	    $message = Data::Dumper::Dumper($message);
	}
	$message = "[$sub] $message\n";
	if ( my $log_file = DEBUG_FILE ) {
	    open(LOG,">> $log_file") || die "Could not open log file: $!";
	    print LOG "$message";
	}
	# print STDERR $message;
    }
}


# singleton!
our $_INSTANCE;

sub new {
    my $class = shift;
    return $_INSTANCE if ($_INSTANCE);

    my %opts = @_;
    my $self = bless [
	# stuff, until it's ready
	undef,             # ALIAS
	undef,             # SESSION
	{},                # GEOMETRY
	{},                # PALETTE
	0,                 # PAL_NUM_SEQ
	[],                # WIN_OUT
	undef,             # WIN_OUT_CUR
	undef,             # WIN_TITLE
	undef,             # WIN_STATUS
	undef,             # WIN_EDIT
	\%opts,            # INIT_OPTS
	undef,             # TAB_COMPLETE
    ], $class;

    $self->init();
    $self->debug("leaving");
    return $self;
}

sub get_alias {
    my $self = shift;
    return $self->[ALIAS];
}

sub init {
    my ($self) = @_;
    $self->debug("entering...");
    $self->trace('Opts', $self->[INIT_OPTS]);

    # set alias
    my $opts = $self->[INIT_OPTS];
    $self->[ALIAS] = $opts->{Alias} || 'chatterm';
    $self->[TAB_COMPLETE] = $opts->{TabComplete} if $opts->{TabComplete};
    # XXX: make this configurable
    my $geometry = {
	TitleHeight  => 1,
	StatusHeight => 1,
	EditHeight   => 1,
    };
    $self->[GEOMETRY] = $geometry;
    $self->init_session();
    $self->debug("leaving");
    return;
}

sub init_session {
    my ($self) = @_;
    $self->debug("entering...");

    # start the POE session, create the Curses wheel
    $self->trace("Creating session");
    my $session = POE::Session->create(
	object_states => [
	    $self => [
		'_start',
		'_stop',
		'send_user_input',
		'curses_input',
		'got_stderr',
		'shutdown',
	    ],
	],
	options => { debug => 0, trace => 0, defaults => 0 },
    );

    $self->trace("Saving to session");
    $self->[SESSION] = $session;
    $self->debug("leaving");
}

sub calc_win_size {
    my $self = shift;
    $self->debug("entering...");

    # what do we know?
    my $geometry = $self->[GEOMETRY];

    @{ $geometry }{qw(cols lines)} = GetTerminalSize();
    $self->trace("LINES (env/curses): " . $geometry->{lines}.'/'.LINES() . ", COLS: " . $geometry->{cols}.'/'.COLS() );

    # get the height of the output screen
    $geometry->{OutputHeight} = $geometry->{lines} - ( List::Util::sum @{ $geometry }{qw(TitleHeight StatusHeight EditHeight)} );

    # figure out the start/end numbers of all these windows

    # Title at top...
    $geometry->{TitleBegin}  = 0;
    $geometry->{TitleEnd}    = $geometry->{TitleBegin} + $geometry->{TitleHeight};
    $self->trace("Title beg/end (height): $geometry->{TitleBegin}/$geometry->{TitleEnd} ($geometry->{TitleHeight})");

    # Output:
    $geometry->{OutputBegin}  = $geometry->{TitleEnd};
    $geometry->{OutputEnd}    = $geometry->{OutputBegin} + $geometry->{OutputHeight};
    $self->trace("Output beg/end (height): $geometry->{OutputBegin}/$geometry->{OutputEnd} ($geometry->{OutputHeight})");

    # status:
    $geometry->{StatusBegin} = $geometry->{OutputEnd};
    $geometry->{StatusEnd}   = $geometry->{StatusBegin}  + $geometry->{StatusHeight};
    $self->trace("Status beg/end (height): $geometry->{StatusBegin}/$geometry->{StatusEnd} ($geometry->{StatusHeight})");

    # edit (height) up from the bottom
    $geometry->{EditBegin}   = $geometry->{StatusEnd};
    $geometry->{EditEnd}     = $geometry->{EditBegin} + $geometry->{EditHeight};
    $self->trace("Edit beg/end (height): $geometry->{EditBegin}/$geometry->{EditEnd} ($geometry->{EditHeight})");


    $self->debug("leaving");
    return;
}

sub _start {
    my ($self,$k,$h) = @_[OBJECT,KERNEL,HEAP];
    $self->debug("entering...");
    my $opts = $self->[INIT_OPTS];

    $k->alias_set($self->[ALIAS]);
    $k->sig( DIE => 'sig_DIE' );

    #
    # clipped from Term::Visual, make the console and handle stderr
    #

    $self->trace("setting up curses wheel and mouse events");
    $h->{console} = POE::Wheel::Curses->new(InputEvent => 'curses_input');

    use_default_colors();
    my $old_mouse_events = 0;
    mousemask(0, $old_mouse_events);

    $self->trace("calculating win size");
    $self->calc_win_size();

    ### Set Colors
    $self->trace("setting up default palette");
    _set_color(
        $self,
        stderr_bullet => "bright white on red",
        stderr_text   => "bright yellow on black",
        ncolor        => "white on black",
        statcolor     => "green on black",
        st_frames     => "bright cyan on blue",
        st_values     => "bright white on blue",
    );

    # use status? fg/bg color?
    $self->trace("setting up status bar");
    unless ( $opts->{StatusBar} => 0 ) {
	$self->init_status_win();
    }

    # use title? fg/bg color?
    $self->trace("setting up title bar");
    unless ( $opts->{TitleBar} => 0 ) {
	$self->init_title_win();
    }

    # input, output screens:
    # for now, input is a one-liner at the bottom,
    # default output will be called "system", which catches server and client
    # messages.
    $self->trace("setting up edit bar");
    $self->init_edit_win();

    $self->trace("setting up system output buffer window");
    my $outwin_sys = $self->create_output_window('system');

    $self->[WIN_OUT][0] = $outwin_sys;
    $self->trace("trying to set CUR to " . $self->[WIN_OUT][0]);
    $self->[WIN_OUT_CUR] = $self->[WIN_OUT][0];
    $self->trace("CUR is " . $self->[WIN_OUT_CUR]);

    $self->trace("setting up STDERR reader");

    ### Redirect STDERR into the terminal buffer.
    my $read_stderr = gensym();
    pipe($read_stderr, STDERR) or do {
        open STDERR, ">&=2";
        die "can't pipe STDERR: $!";
    };

    $h->{stderr_reader} = POE::Wheel::ReadWrite->new(
        Handle      => $read_stderr,
        Filter      => POE::Filter::Line->new(),
        Driver      => POE::Driver::SysRW->new(),
        InputEvent  => "got_stderr",
    );

    $self->debug("leaving");

}

sub _stop {
    my ($self,$kernel, $heap) = @_[OBJECT, KERNEL, HEAP];
    $self->debug("entering...");

    $self->trace( Carp::longmess() );
    $self->trace( $kernel );

    $kernel->alias_remove($self->[ALIAS]);
    delete $heap->{stderr_reader};
    delete $heap->{console};

    if (defined $heap->{input_session}) {
        $kernel->refcount_decrement( $heap->{input_session}, "termlink" );
        delete $heap->{input_session};
    }

    $self->debug("leaving");

}

sub shutdown {
    my ($self,$k) = $_[OBJECT,KERNEL];
    $self->debug("entering...");
    $k->yield('_stop');
    $self->debug("leaving");
}

# sub handle_sigwinch {
#     my ($self,$k,$sig) = @_[OBJECT,KERNEL,ARG0];
#     $self->debug("entering...");
#     $self->trace("Sig: $sig");
#     $self->refresh_screen();
#     $k->sig_handled();
#     $self->debug("leaving");
# }

sub sig_DIE {
    my ($self,$sig,$ex) = @_[OBJECT,ARG0,ARG1];
    $self->debug("Signal: $sig", $ex);
    return;
}

sub refresh_screen {
    my ($self) = @_[OBJECT];
    $self->debug("entering...");
    endwin();
    refresh();
    $self->calc_win_size();
    $self->init_title_win();
    $self->init_status_win();
    $self->refresh_output_window();
    $self->init_edit_win();
    $self->debug("leaving");
}


# this comes from the session using the screen, adapted from Term::Visual
sub send_user_input {
    my ($self,$h,$k,$sender,$user_input_event) = @_[OBJECT,HEAP,KERNEL,SENDER,ARG0];
    $self->debug("entering...");

    $h->{input_session} = $sender->ID();
    $h->{input_event}   = $user_input_event;
    $self->trace("Input session/event: " . join('/', @{$h}{qw(input_session input_event)}));

    # keep session alive while term's here, decrement in _stop
    $k->refcount_increment( $sender->ID(), 'termlink' );
    $self->debug("leaving");

}

#
# taken from Term::Visual for processing input from Curses input screen
#
sub curses_input {
    my ($self,$h,$k,$key) = @_[OBJECT,HEAP,KERNEL,ARG0];
    $self->debug("entering...");

    my $outwin = $self->[WIN_OUT_CUR];
    my $inwin  = $self->[WIN_EDIT];

    $self->debug("Key coming in is $key");
    $key = uc(keyname($key)) if $key =~ /^\d{2,}$/;
    $key = uc(unctrl($key))  if $key lt " " or $key gt "~";

    # If it's a meta key, save it.
    if ($key eq '^[') {
	$self->debug("saving meta key to inwin:Prefix");
        $inwin->{Prefix} .= $key;
	$self->debug("speed leaving");
        return;
    }

    # If there was a saved prefix, recall it.
    if ($inwin->{Prefix}) {
	$self->debug("making meta from prefix/key: '$inwin->{Prefix}'/'$key'");
        $key = $inwin->{Prefix} . $key;
        $inwin->{Prefix} = '';
    }

    # when we're ready for bindings...
    #if (exists $self->[BINDINGS]{$key} and $heap->{input_session}) {
    #    $kernel->post( $heap->{input_session}, $self->[BINDINGS]{$key},
    #                   $key, $winref
    #               );
    #    return;
    #}

    # Back/Forth one character.
    if ( ($key eq 'KEY_LEFT' || $key eq 'KEY_RIGHT') && $inwin->{Cursor} ) {
	if ( $key eq 'KEY_LEFT' ) {
	    $inwin->{Cursor}--;
	} else {
	    $inwin->{Cursor}++;
	}
	_refresh_edit($self);
        return;
    }

    # KEY_UP/KEY_DOWN: history
    if ( $key eq "KEY_UP" || $key eq "KEY_DOWN" ) {
	my $hist_updown = $key eq 'KEY_UP' ? 1 : 2;
	_command_history($self,$hist_updown);
	return;
    }

    # ctrl-KEY_UP/KEY_DOWN should do buffer scrolling
    # not sure if this is portable enough, should look for keyname way to do this?
    if ( $key eq '^[[1;5A' || $key eq '^[[1;5B' ) {
	if ( $key eq '^[[1;5A' && ($inwin->{Buffer_Row} > $inwin->{Buffer_First}) ) 
	{
            $inwin->{Buffer_Row}--;
	}
	elsif ( $key eq '^[[1;5B' && ($inwin->{Buffer_Row} < $inwin->{Buffer_Last}) ) 
	{
            $inwin->{Buffer_Row}++;
	}
	_refresh_buffer($self);
	return;
    }

    # will need to catch the interrupt...
    if ($key eq '^\\' || $key eq '^C' ) {
	$self->trace("caught an interrupt");
	$k->yield('_stop');
        $k->signal($k, "UIDESTROY");
	$self->debug("speed leaving");
        return;
    }

    # Backward delete character.
    if ($key eq '^H' or $key eq "^?" or $key eq 'KEY_BACKSPACE') {
        if ($inwin->{Cursor} && $inwin->{Cursor} > ($inwin->{Prompt_Size} ) ) {
	    $inwin->{Cursor}--;
	    substr($inwin->{Data}, $inwin->{Cursor} - $inwin-> {Prompt_Size}, 1) = '';
	    _refresh_edit($self);
	    doupdate();
        }
	$self->debug("speed leaving");
        return;
    }

    # winch?
    if ($key eq '^L' || $key eq 'KEY_RESIZE') {
	$self->refresh_screen();
	$self->debug("speed leaving");
        return;
    }

    # begining of line
    if ( ($key eq '^A' || $key eq '^E') && $inwin->{Cursor} ) {
	if ( $key eq '^A' ) {
	    $inwin->{Cursor} = 0;
	} else {
	    $inwin->{Cursor} = length($inwin->{Data});
	}
	$inwin->{Cursor} += $inwin->{Prompt_Size} if $inwin->{Prompt_Size};
	_refresh_edit($self);
        return;
    }

    # kill (kill ring?)
    if ($key eq '^K') {
	#
	# XXX: This needs to kill everything from the cursor to the end, not the whole line
	#

	$inwin->{KillRing} = $inwin->{Data};
	# for now, one yank should do, but this should be a list...

	$inwin->{Data} = '';
	$inwin->{Cursor} = 0;
	$inwin->{Cursor} += $inwin->{Prompt_Size} if $inwin->{Prompt_Size};
	_refresh_edit($self);
	return;
    }
    if ($key eq '^Y') {
	$inwin->{Data} .= $inwin->{KillRing};
	$inwin->{Cursor} = length($inwin->{Data});
	$inwin->{Cursor} += $inwin->{Prompt_Size} if $inwin->{Prompt_Size};
	_refresh_edit($self);
	return;
    }

    if ($key eq "^I" && $self->[TAB_COMPLETE] ) {
	my $left = substr($inwin->{Data}, 0, $inwin->{Cursor});
	my $right = substr($inwin->{Data}, $inwin->{Cursor});

	# this is the list of completions to check
	my $str = $self->[TAB_COMPLETE]->($left, $right);

	my $data = $str;
	# set the Data of the line, and the cursor position and update
	$inwin->{Data} = $data . $right;
	$inwin->{Cursor} = length $data;
	$inwin->{Cursor} += $inwin->{Prompt_Size} if $inwin->{Prompt_Size};
	_refresh_edit($self);
        return;
    }

    # Accept line.
    if ($key eq '^J' or $key eq '^M') {
	$self->trace("posting line to input session/event");
        $k->post( $h->{input_session}, $h->{input_event},
                       $inwin->{Data}, undef
                   );

        # And enter the line into the command history.
	$self->trace("adding line to command history");
	_command_history( $self, 0 );
	$self->debug("speed leaving");
        return;
    }


    ### Not an internal keystroke.  Add it to the input buffer.

    $self->trace("just adding key to edit buffer: $key");

    # Inserting or overwriting in the middle of the input.
    if ($inwin->{Cursor} < length( $inwin->{Prompt}.$inwin->{Data} ))
    {
	my $insert_point = $inwin->{Cursor};
	$insert_point -= $inwin->{Prompt_Size} if $inwin->{Prompt_Size};

	$self->trace(
	    "length Data|Prompt: ".join('|',length($inwin->{Data}),$inwin->{Prompt_Size}),
	    "insert_point: $insert_point",
	    "command: substr( '$inwin->{Data}'. $insert_point, 0 ) = '$key'",
	    "key: $key",
	);
	substr($inwin->{Data}, $insert_point, 0) = $key;
	$self->trace("Data after insert: $inwin->{Data}");

    }
    # Appending.
    else
    {
        $inwin->{Data} .= $key;
    }

    $inwin->{Cursor} += length($key);
    _refresh_edit($self);

    $self->debug("leaving");
    return;

}

sub got_stderr {
    my ($self, $kernel, $stderr_line) = @_[OBJECT, KERNEL, ARG0];

    $self->print(
           "\0(stderr_bullet)" .
           "2>" .
           "\0(ncolor)" .
           " " .
           "\0(stderr_text)" .
           "[ $stderr_line ]" .
	   "\0(ncolor)"
       );
}

sub init_status_win {
    my ($self) = @_;
    $self->debug("entering...");

    my $geo = $self->[GEOMETRY];
    my $status = $self->[WIN_STATUS] ||
    {
	format      => "",
	fields      => {},
	text        => '',
    };
    $status->{window} = newwin( $geo->{StatusHeight}, $geo->{cols}, $geo->{StatusBegin}, 0 );
    $self->[WIN_STATUS] = $status;

    $status->{window}->erase();
    _refresh_status($self);

    $self->debug("leaving");
    return;
}

sub init_title_win {
    my ($self) = @_;
    $self->debug("entering...");

    my $geo = $self->[GEOMETRY];
    my $title = $self->[WIN_TITLE] || {
	text => 'Title',
    };
    $self->trace("Creating title window at " . join(' | ', ( $geo->{TitleHeight}, $geo->{cols}, $geo->{TitleBegin}, 0 ) ) );
    $title->{window} = newwin( $geo->{TitleHeight}, $geo->{cols}, $geo->{TitleBegin}, 0 ),
    $self->[WIN_TITLE] = $title;

    $title->{window}->erase();
    _refresh_title($self);
    $self->debug("leaving");
    return;
}

sub init_edit_win {
    my $self = shift;
    $self->debug("entering...");

    my $geo = $self->[GEOMETRY];

    my $edit = $self->[WIN_EDIT] || {
	History_Position => -1,
	History_Size     => 50,
	Command_History  => [ ],
	Data             => "",
	Data_Save        => "",
	Cursor           => 3,
	Cursor_Save      => 0,
	Insert           => 1,
	Edit_Position    => 0,
	Prompt           => '>> ',
	Prompt_Size      => 3,
	KillRing         => '',
	PagerActive      => 0,
    };
    $edit->{window} = newwin( $geo->{EditHeight}, $geo->{cols}, $geo->{EditBegin}, 0 );
    $self->[WIN_EDIT] = $edit;

    $edit->{window}->erase();
    $edit->{window}->noutrefresh();
    $edit->{window}->scrollok(1);
    _refresh_edit($self);

    $self->debug("leaving");
    return;
}

sub create_output_window {
    my ($self,$name) = @_;
    $self->debug("entering...");

    die "Must provide window name!" unless $name;

    $self->debug("creating output window");
    # XXX: make this settable
    my $outwin = {
	Name       => $name,
	Buffer_Size => 100,
	Buffer     => [],
	Buffer_Row => '',
	Scrolled_Lines => 0,
    };

    my $geo = $self->[GEOMETRY];
    $outwin->{window} = newwin(
	$geo->{OutputHeight},
	$geo->{cols},
	$geo->{OutputBegin},
	0
    );
    $self->trace($geo);
    $self->trace($outwin);

    $self->trace("buffer first,last,visible");
    $outwin->{Buffer_Last}    = $outwin->{Buffer_Size} - 1;
    $outwin->{Buffer_First}   = $geo->{OutputHeight} - 1;
    $outwin->{Buffer_Visible} = $geo->{OutputHeight} - 1;

    $self->trace("set up screen");
    die unless $outwin->{window};
    $self->trace("- background");
    $outwin->{window}->bkgd( $self->[PALETTE]->{ncolor}->[PAL_PAIR] );
    $self->trace("- erase");
    $outwin->{window}->erase();
    $self->trace("- noutrefresh");
    $outwin->{window}->noutrefresh();

    $self->trace("setting buffer row");
    $outwin->{Buffer_Row} = $outwin->{Buffer_Last};
    $outwin->{Buffer} = [("") x $outwin->{Buffer_Size}];

    $self->debug("leaving");
    return $outwin;

}

sub refresh_output_window {
    my $self = shift;

    my $curwin = $self->[WIN_OUT_CUR];
    $self->trace("set up screen");
    die "No current window!" unless $curwin->{window};

    my $geo = $self->[GEOMETRY];

    $curwin->{window} = newwin(
	$geo->{OutputHeight},
	$geo->{cols},
	$geo->{OutputBegin},
	0
    );
    # $self->trace($geo);
    # $self->trace($curwin);

    $self->trace("buffer first,visible");
    $curwin->{Buffer_First}   = $geo->{OutputHeight} - 1;
    $curwin->{Buffer_Visible} = $geo->{OutputHeight} - 1;

    $self->trace("- background");
    $curwin->{window}->bkgd( $self->[PALETTE]->{ncolor}->[PAL_PAIR] );
    $self->trace("- erase");
    $curwin->{window}->erase();
    $self->trace("- noutrefresh");
    $curwin->{window}->noutrefresh();

    _refresh_buffer($self);

    $self->debug("leaving");

}

#
# exposed object methods:
#

sub set_palette {
    my $self = shift;
    $self->debug("entering...");
    my %params = @_;
    _set_color($self,%params);
    $self->debug("leaving");
}

# set the title bar text
sub set_title_text {
    my ($self,$text) = @_;
    $self->debug("entering...");
    chomp($text);

    return unless $self->[WIN_TITLE];

    $self->[WIN_TITLE]->{text} = $text;
    $self->trace("refreshing title to: $text");
    _refresh_title($self);
    $self->debug("leaving");
}

# set the status bar text
sub set_status_format {
    my ($self,$format) = @_;
    $self->debug("entering...");
    $self->[WIN_STATUS]->{format} = $format;
    $self->debug("leaving");
}

sub set_status_fields {
    my ($self,%fields) = @_;
    $self->debug("entering...");

    my $stat = $self->[WIN_STATUS];
    foreach my $field ( %fields ) {
	$stat->{fields}->{$field} = $fields{$field};
    }
    $self->debug("leaving");
}

sub update_status {
    my ($self) = @_;
    $self->debug("entering...");

    my $stat = $self->[WIN_STATUS] || return;
    my $format = $stat->{format}   || return;
    my $text   = $format;
    my $fields = $stat->{fields}   || return;

    foreach my $field ( %$fields ) {
	my $val = $fields->{$field};
	$text =~ s/\[\%\s*$field\s*\%\]/$val/g;
    }
    $stat->{text} = $text;
    _refresh_status($self);
    $self->debug("leaving");
}

sub print {

    my ($self,@text) = @_;
    $self->debug("entering...");

    if ( ! $self->[WIN_OUT] || ! $self->[WIN_OUT_CUR] ) {
	$self->trace("BAILING! WIN_OUT:" . $self->[WIN_OUT] . ", WIN_OUT_CUR:" . $self->[WIN_OUT_CUR] );
	return ;
    }
    my $outwin = $self->[WIN_OUT_CUR];
    my $geo = $self->[GEOMETRY];

    $self->trace("splitting lines");
    my @lines;
    foreach my $l (@text) {
        foreach my $ll (split(/\n/,$l)) {
            $ll =~ s/\r//g;
            push(@lines,$ll);
        }
    }

    $self->trace("processing lines");
    foreach my $line (@lines) {

	$self->trace("new line in scrollback buffer");
         # Start a new line in the scrollback buffer.
         push @{$outwin->{Buffer}}, "";
         $outwin->{Scrolled_Lines}++;
         my $column = 1;

	 # Build a scrollback line.  Stuff surrounded by \0() does not take
         # up screen space, so account for that while wrapping lines.
         my $last_color = "\0(ncolor)";
         while ( length($line) ) {

	     $self->trace("- checking for color code");
             # Unprintable color codes.
	     if ($line =~ s/^(\0\([^\)]+\))//) {
                 $outwin->{Buffer}->[-1] .= $last_color = $1;
                 next;
             }

	     $self->trace("- checking for visible");
             # Wordwrap visible stuff.
	     if ($line =~ s/^([^\0]+)//) {
                my @words = split /(\s+)/, $1;

		$self->trace("- processing words");
                foreach my $word (@words) {

                    unless (defined $word) {
                        warn "undefined word";
			next;
		    }

		    while ($column + length($word) >= $geo->{cols}) {

			$self->trace("- word wrapping");
                         # maybe this word length should be configurable
                         if (length($word) > 20) {

                             # save the word
                             my $preword = $word;

                             # shorten the word to the end of the line
                             $word = substr($word,0,($geo->{cols} - $column));

                             # add the word
                             $outwin->{Buffer}->[-1] .= "$word\0(ncolor)";
                             $word = '';

                             # put the last color on the next line and wrap
                             push @{$outwin->{Buffer}}, $last_color;
                             $outwin->{Scrolled_Lines}++;

                             # slice the unmodified word
                             $word = substr($preword,($geo->{cols} - $column));
                             $column = 1;
                             next;
                         }
                         else
			 {
                             $outwin->{Buffer}->[-1] .= "\0(ncolor)";
                             push @{$outwin->{Buffer}}, $last_color;
                         }
                         $outwin->{Scrolled_Lines}++;
                         $column = 1;
                         next if $word =~ /^\s+$/;
                     }

		    $self->trace("- putting word on buffer");
		    $outwin->{Buffer}->[-1] .= $word;
		    $column += length($word);
		    $word = '';
		}
	    }
         }
     }

    $self->trace("- splicing scrollback");
    # Keep the scrollback buffer a tidy length.
    splice(@{$outwin->{Buffer}}, 0, @{$outwin->{Buffer}} - $outwin->{Buffer_Size}) if @{$outwin->{Buffer}} > $outwin->{Buffer_Size};

    # Refresh the buffer when it's all done.
    $self->trace("- refreshing out buffer");
    _refresh_buffer($self);

    $self->trace("- refreshing edit");
    _refresh_edit($self);

    $self->debug("leaving");
    return;
}


#
# Internals
#
my %ctrl_to_visible;
BEGIN {
    for (0..31) {
        $ctrl_to_visible{chr($_)} = chr($_+64);
    }
}

sub _refresh_edit {

    my $self = shift;
    $self->debug("entering...");

    my $geo           = $self->[GEOMETRY];
    my $inwin         = $self->[WIN_EDIT];
    my $edit          = $inwin->{window};
    my $visible_input = $inwin->{Data};
    $self->trace("Got inwin, window, visible input");
    $self->trace("visible input: $visible_input");

    # If the cursor is after the last visible edit position, scroll the
    # edit window left so the cursor is back on-screen.
    if ($inwin->{Cursor} - $inwin->{Edit_Position} >= $geo->{cols}) {
        $inwin->{Edit_Position} = $inwin->{Cursor} - $geo->{cols} + 1;
	$self->trace("scrolling left to Edit_Position $inwin->{Edit_Position}");
    }

    # If the cursor is moving left of the middle of the screen, scroll
    # things to the right so that both sides of the cursor may be seen.

    elsif ($inwin->{Cursor} - $inwin->{Edit_Position} < ($geo->{cols} >> 1)) {
        $inwin->{Edit_Position} = $inwin->{Cursor} - ($geo->{cols} >> 1);
        $inwin->{Edit_Position} = 0 if $inwin->{Edit_Position} < 0;
	$self->trace("scrolling right to Edit_Position $inwin->{Edit_Position}");
    }

    # If the cursor is moving right of the middle of the screen, scroll
    # things to the left so that both sides of the cursor may be seen.
    elsif ( $inwin->{Cursor} <= length($inwin->{Data}) - ($geo->{cols} >> 1) + 1 ) {
        $inwin->{Edit_Position} = $inwin->{Cursor} - ($geo->{cols} >> 1);
	$self->trace("scrolling left to Edit_Position $inwin->{Edit_Position}");
    }

    # Condition $visible_input so it really is.
    $visible_input = substr($visible_input, $inwin->{Edit_Position}, $geo->{cols} - 1);

    $self->trace("start with normal, erase, update");
    $edit->attron(A_NORMAL);
    $edit->erase();
    $edit->noutrefresh();

    if ($inwin->{Prompt}) {
	$self->trace("adding cursor string");
        $visible_input = $inwin->{Prompt} . $visible_input;
	if ( $inwin->{Cursor} > (length($visible_input)) ) {
	    $inwin->{Cursor} = (length($visible_input));
	}

    }

    $self->trace("adding strings to edit window");
    while (length($visible_input)) {
        if ($visible_input =~ /^[\x00-\x1f]/) {
            $edit->attron(A_UNDERLINE);
            while ($visible_input =~ s/^([\x00-\x1f])//) {
                $edit->addstr($ctrl_to_visible{$1});
            }
        }
        if ($visible_input =~ s/^([^\x00-\x1f]+)//) {
            $edit->attroff(A_UNDERLINE);
            $edit->addstr($1);
        }
    }

    $self->trace("refresh and move to position: " . ($inwin->{Cursor} - $inwin->{Edit_Position}) );
    $edit->noutrefresh();
    $edit->move( 0, $inwin->{Cursor} - $inwin->{Edit_Position} );
    $edit->noutrefresh();

    $self->trace("dopupdate...");
    doupdate();

    $self->debug("leaving");
    return;
}

sub _refresh_title {
    my ($self) = @_;
    $self->debug("entering...");

    my $title = $self->[WIN_TITLE];
    return unless $title;
    my $title_win = $title->{window};
    return unless $title_win;
    $self->trace("have title and win");

    my $geo = $self->[GEOMETRY];
    my $title_text = $title->{text};
    my $title_fill = ' ' x ( $geo->{cols} - length($title_text) );
    $title_text .= $title_fill;
    $self->trace("title text>> '$title_text'");
    $self->trace("title length: " . length( $title_text ) . ", cols: " . $geo->{cols});

    $self->trace("moving to 0,0");
    $title_win->move(0,0);
    $self->trace("setting palette and refreshing");
    $title_win->attrset($self->[PALETTE]->{st_values}->[PAL_PAIR]);
    $title_win->noutrefresh();
    $self->trace("adding title text");
    $title_win->addstr($title_text);
    $title_win->noutrefresh();
    $self->trace("clearing to end of line and updating");
    #$title_win->clrtoeol();
    $title_win->noutrefresh();
    $self->trace("doupdate");
    doupdate();

    $self->debug("leaving");
    return;
}

sub _refresh_status {
    my ($self) = @_;
    $self->debug("entering...");

    return if ! ( my $status = $self->[WIN_STATUS] );

    my $geo = $self->[GEOMETRY];
    my $status_text = $status->{text};
    my $status_fill = ' ' x ( $geo->{cols} - length($status_text) );
    $status_text .= $status_fill;

    my $statuswin = $status->{window};
    $statuswin->attrset($self->[PALETTE]->{st_frames}->[PAL_PAIR]);
    $statuswin->move(0,0);
    $statuswin->addstr($status_text);
    $statuswin->noutrefresh();
    $statuswin->clrtoeol();
    $statuswin->noutrefresh();
    doupdate();

    $self->debug("leaving");
    return;
}

sub _refresh_buffer {

    my $self = shift;
    $self->debug("entering...");
    # $self->trace($self->[WIN_OUT_CUR]);

    my $outwin = $self->[WIN_OUT_CUR] || return;
    my $screen = $outwin->{window}    || return;
    my $geo    = $self->[GEOMETRY];

    # Adjust the buffer row to compensate for any scrolling we encounter
    # while in scrollback.
    if ($outwin->{Buffer_Row} < $outwin->{Buffer_Last}) {
        $outwin->{Buffer_Row} -= $outwin->{Scrolled_Lines};
    }

    # Don't scroll up past the start of the buffer.
    if ($outwin->{Buffer_Row} < $outwin->{Buffer_First}) {
        $outwin->{Buffer_Row} = $outwin->{Buffer_First};
    }

    # Don't scroll down past the bottom of the buffer.
    if ($outwin->{Buffer_Row} > $outwin->{Buffer_Last}) {
        $outwin->{Buffer_Row} = $outwin->{Buffer_Last};
    }

    # Now splat the last N lines onto the screen.
    $screen->erase();
    $screen->noutrefresh();
    $outwin->{Scrolled_Lines} = 0;

    my $screen_y = 0;
    my $buffer_y = $outwin->{Buffer_Row} - $outwin->{Buffer_Visible};

    while ($screen_y < $self->[GEOMETRY]->{OutputHeight}) {

	$self->trace("Moving to output screen line: $screen_y");
        $screen->move($screen_y, 0);
        $screen->clrtoeol();
        $screen->noutrefresh();

        if ( $buffer_y < 0 ) {
	    $self->trace("buffer_y < 0: $buffer_y");
	    next;
	}

        if ( $buffer_y > $outwin->{Buffer_Last} ) {
	    $self->trace("buffer_y ($buffer_y) > Buffer_Last ($outwin->{Buffer_Last})");
	    next;
	}

        next if $buffer_y > $outwin->{Buffer_Last};

	$self->trace("Getting line index '$buffer_y' from buffer: '".$outwin->{Buffer}->[$buffer_y]."'");
        my $line = $outwin->{Buffer}->[$buffer_y]; # does this work?
        my $column = 1;
        while (length $line) {
            while ($line =~ s/^\0\(([^)]+)\)//) {
                my $cmd = $1;
                if ($cmd =~ /blink_(on|off)/) {
                    if ($1 eq 'on') {
                        $screen->attron(A_BLINK);
                    }
                    if ($1 eq 'off') {
                        $screen->attroff(A_BLINK);
                    }
                    $screen->noutrefresh();
                }
                elsif ($cmd =~ /bold_(on|off)/) {
                    if ($1 eq 'on') {
                        $screen->attron(A_BOLD);
                    }
                    if ($1 eq 'off') {
                        $screen->attroff(A_BOLD);
                    }
                    $screen->noutrefresh();
                }
                elsif ($cmd =~ /underline_(on|off)/) {
                    if ($1 eq 'on') {
                        $screen->attron(A_UNDERLINE);
                    }
                    if ($1 eq 'off') {
                        $screen->attroff(A_UNDERLINE);
                    }
                    $screen->noutrefresh();
                }
                else {
                    $screen->attrset($self->[PALETTE]->{$cmd}->[PAL_PAIR]); 
                    $screen->noutrefresh();
                }
            }

	    if ($line =~ s/^([^\0]+)//x) {
                # TODO: This needs to be revised so it cuts off the last word,
                # not omits it entirely.
                # Has this been fixed already??
                next if $column >= $geo->{cols};
                if ($column + length($1) > $geo->{cols}) {
                    my $word = $1;
                    substr($word, ($column + length($1)) - $geo->{cols} - 1) = '';
                    $screen->addstr($word);
                }
                else {
                    $screen->addstr($1);
                }
                $column += length($1);
                $screen->noutrefresh();
            }
        }

        $screen->attrset($self->[PALETTE]->{ncolor}->[PAL_PAIR]);
        $screen->noutrefresh();
        $screen->clrtoeol();
        $screen->noutrefresh();
    }
    continue
    {
        $screen_y++;
        $buffer_y++;
	$self->trace("increment screen/buffer: $screen_y/$buffer_y");
    }
    $self->trace("update screen");
    doupdate();

    $self->debug("leaving");
    return;
}

sub _command_history {
    my ($self,$flag) = @_;
    $self->debug("entering");

    my $editref = $self->[WIN_EDIT];
    $self->trace($editref ? "got editref" : "no editref!" );
    if ( ! $editref ) {
	die "No edit window!";
    }

    if ($flag == 0) {
	$self->trace("adding to command history");
        # Add to the command history.  Discard the oldest item if the
        # history size is bigger than our maximum length.

        unshift(
	    @{$editref->{Command_History}},
	    $editref->{Data}
	);
	if ( @{ $editref->{Command_History} } > $editref->{History_Size} ) {
	    pop(@{$editref->{Command_History}});
	}

        # Reset the input, saved input, and history position.  Repaint the edit box.
	$self->trace("resetting Data, Data_Save, Cursor, and History_Position");
        $editref->{Data_Save} = $editref->{Data} = "";
        $editref->{Cursor_Save} = $editref->{Cursor} = $editref->{Prompt_Size} || 0;
        $editref->{History_Position} = -1;

	$self->trace("refreshing");
        _refresh_edit($self);

	$self->debug("speed leaving");
        return;
    }

    if ($flag == 1) {
	$self->trace("get last from command history");
	# get last history 'KEY_UP'

        # At <0 command history, we save the input and move into the
        # command history.  The saved input will be used in case we come back.

        if ($editref->{History_Position} < 0) {
            if ( @{$editref->{Command_History}} ) {
                $editref->{Data_Save}   = $editref->{Data};
                $editref->{Cursor_Save} = $editref->{Cursor};
                $editref->{Data}        = $editref->{Command_History}->[ ++$editref->{History_Position} ];
                $editref->{Cursor}      = length($editref->{Data});
                if ($editref->{Prompt_Size}) {
                    $editref->{Cursor} += $editref->{Prompt_Size};
                }
                _refresh_edit($self);
            }
        }
	else
	{
	    my $index;
	    if ( $editref->{History_Position} < $#{ $editref->{Command_History} } ) {
		$index = ++$editref->{History_Position};
	    } else {
		$index = $#{ $editref->{Command_History} };
	    }

	    # If we're not at the end of the command history, then we go farther back.
            $editref->{Data} = $editref->{Command_History}->[$index];
            $editref->{Cursor} = length($editref->{Data});
            if ($editref->{Prompt_Size}) {
                $editref->{Cursor} += $editref->{Prompt_Size};
            }
            _refresh_edit($self);
        }

	$self->debug("speed leaving");
        return;
    }

    if ($flag == 2) {
	$self->trace("get next from command history");
	# get next history 'KEY_DOWN'
        # At 0th command history.  Switch to saved input.
        unless ($editref->{History_Position}) {
            $editref->{Data} = $editref->{Data_Save};
            $editref->{Cursor} = $editref->{Cursor_Save};
            $editref->{History_Position}--;
            _refresh_edit($self);
        }

        # At >0 command history.  Move towards 0.
        elsif ($editref->{History_Position} > 0) {
            $editref->{Data} = $editref->{Command_History}->[--$editref->{History_Position}];
            $editref->{Cursor} = length($editref->{Data});
            if ($editref->{Prompt_Size}) {
                $editref->{Cursor} += $editref->{Prompt_Size};
            }
            _refresh_edit($self);
        }

        return;
	$self->debug("speed leaving");
    }

    warn "unknown flag $flag";
    $self->debug("leaving");
}

#
# internal palette setting  method,
# shamelessly hack-dapted from Term::Visual
#

our (%color_table, %attribute_table);
BEGIN {
    %color_table = (
	bk      => COLOR_BLACK,    black   => COLOR_BLACK,
	bl      => COLOR_BLUE,     blue    => COLOR_BLUE,
	br      => COLOR_YELLOW,   brown   => COLOR_YELLOW,
	fu      => COLOR_MAGENTA,  fuschia => COLOR_MAGENTA,
	cy      => COLOR_CYAN,     cyan    => COLOR_CYAN,
	gr      => COLOR_GREEN,    green   => COLOR_GREEN,
	ma      => COLOR_MAGENTA,  magenta => COLOR_MAGENTA,
	pu      => COLOR_MAGENTA,  purple  => COLOR_MAGENTA,
	re      => COLOR_RED,      red     => COLOR_RED,
	wh      => COLOR_WHITE,    white   => COLOR_WHITE,
	ye      => COLOR_YELLOW,   yellow  => COLOR_YELLOW,
	de      => -1,             default => -1,
    );


    %attribute_table = (
	al         => A_ALTCHARSET,
	alt        => A_ALTCHARSET,
	alternate  => A_ALTCHARSET,
	blink      => A_BLINK,
	blinking   => A_BLINK,
	bo         => A_BOLD,
	bold       => A_BOLD,
	bright     => A_BOLD,
	dim        => A_DIM,
	fl         => A_BLINK,
	flash      => A_BLINK,
	flashing   => A_BLINK,
	hi         => A_BOLD,
	in         => A_INVIS,
	inverse    => A_REVERSE,
	inverted   => A_REVERSE,
	invisible  => A_INVIS,
	inviso     => A_INVIS,
	lo         => A_DIM,
	low        => A_DIM,
	no         => A_NORMAL,
	norm       => A_NORMAL,
	normal     => A_NORMAL,
	pr         => A_PROTECT,
	prot       => A_PROTECT,
	protected  => A_PROTECT,
	reverse    => A_REVERSE,
	rv         => A_REVERSE,
	st         => A_STANDOUT,
	stand      => A_STANDOUT,
	standout   => A_STANDOUT,
	un         => A_UNDERLINE,
	under      => A_UNDERLINE,
	underline  => A_UNDERLINE,
	underlined => A_UNDERLINE,
	underscore => A_UNDERLINE,
    );
}

sub _set_color {
    my $self= shift;
    $self->debug("entering...");

    my %params = @_;

    for my $color_name (keys %params) {

        my $description = $params{$color_name};
        my $foreground = 0;
        my $background = 0;
        my $attributes = 0;

        # Which is an alias to foreground or background depending on what state we're in.
        my $which = \$foreground;

        # Clean up the color description.
        $description =~ s/^\s+|\s+$//g;
        $description = lc($description);

        # Parse the description.
        foreach my $word (split /\s+/, $description) {

            # The word "on" means we're switching to background.
            if ($word eq 'on') {
                $which = \$background;
                next;
            }
            # If it's a color name, combine its value with the foreground or
            # background, whichever is currently selected
            if (exists $color_table{$word}) {
                $$which |= $color_table{$word};
                next;
            }

            # If it's an attribute, it goes with attributes.
            if (exists $attribute_table{$word}) {
                $attributes |= $attribute_table{$word};
                next;
            }

            # Otherwise it's an error.
	    my $err = "unknown color keyword \"$word\"";
	    $self->debug($err, Carp::longmess);
            croak($err);
        }

        # If the palette already has that color, redefine it.
        if ( exists $self->[PALETTE]->{$color_name} )
	{
            my $old_color_number = $self->[PALETTE]->{$color_name}->[PAL_NUMBER];
            init_pair($old_color_number, $foreground, $background);
            $self->[PALETTE]->{$color_name}->[PAL_PAIR] = COLOR_PAIR($old_color_number) | $attributes;
        }
        else
	{
            my $new_color_number = ++$self->[PAL_NUM_SEQ];
            init_pair($new_color_number, $foreground, $background);
            $self->[PALETTE]->{$color_name} = [
		COLOR_PAIR($new_color_number) | $attributes, # PAL_PAIR
		$new_color_number,                           # PAL_NUMBER
		$description,                                # PAL_DESC
	    ];
        }
    }
    $self->debug("leaving");

}


















#
# New Constructors:
#
# Alias (session alias)
# Scrollback $lines
#
# StatusBar 0|1
# StatusFG, StatusBG
# TitleBar 0|1
# TitleFG, TitleBG
# InputFG, InputBG
# OutputFG, OutputBG
#

=pod

my $outwin _example_thing = {
    name   => $name,
    window => $win,
    Input  => {
	Prefix        => '',
	Cursor        => $cur_pos,
	Prompt        => $prompt,
	PromptSize    => $p_size,
	Data          => '',
	Tab_Complete  => $code_ref,
	Edit_Position => 0,
	Command_History  => [],
	History_Size     => 10,
	History_Position => 0,
	Cursor_Save      => ''.
    },

    Scrolled_Lines => 0,
    Screen_Height  => 0,
    Buffer         => [],
    Buffer_Row     => $rowwww,
    Buffer_First   => 0,
    Buffer_Last    => 0,
};

=cut

1;
