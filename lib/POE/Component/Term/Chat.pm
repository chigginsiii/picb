package POE::Component::Term::Chat;

use strict;
use Curses;
use POE qw(Wheel::Curses Filter::Line Wheel::ReadWrite);

use POE::Component::Term::Chat::StatusBar;
use POE::Component::Term::Chat::EditWindow;
use POE::Component::Term::Chat::OutputWindow;

use Symbol qw(gensym);
use Readonly;
use Term::ReadKey;
use List::Util qw();
use List::MoreUtils qw();
use Data::Dumper;

$|++;

#
# accessor constants
#
Readonly::Scalar our $TERM        => 0;
Readonly::Scalar our $PARAMS      => 1;
# meta
Readonly::Scalar our $OUT_BUFFERS => 2;
Readonly::Scalar our $CUR_BUFFER  => 3;
Readonly::Scalar our $TITLE       => 4;
Readonly::Scalar our $STATUS      => 5;
Readonly::Scalar our $EDIT        => 6;
# windows
Readonly::Scalar our $WIN_OUT     => 7;
Readonly::Scalar our $WIN_TITLE   => 8;
Readonly::Scalar our $WIN_STATUS  => 9;
Readonly::Scalar our $WIN_EDIT    => 10;
# colors
Readonly::Scalar our $PALETTE     => 11;
Readonly::Scalar our $PAL_NUM_SEQ => 12;
# tab completion (callback? postback?)
Readonly::Scalar our $TAB_COMPLETE => 13;
Readonly::Scalar our $GEOMETRY     => 14;

#
# palette pair idx
#
Readonly::Scalar our $PAL_PAIR   => 0;
Readonly::Scalar our $PAL_NUMBER => 1;
Readonly::Scalar our $PAL_DESC   => 1;

sub new {

    my $class = shift;
    my $self = [
	undef,         # $TERM
	{},            # $PARAMS
	## meta
	[],            # $OUT_BUFFERS
	undef,         # $CUR_BUFFER
	undef,         # $TITLE
	undef,         # $STATUS
	undef,         # $EDIT
	## actual curses windows
	undef,         # $WIN_OUT
	undef,         # $WIN_TITLE
	undef,         # $WIN_STATUS
	undef,         # $WIN_EDIT
	# colors
	undef,         # $PALETTE
	0,             # $PAL_NUM_SEQ
	undef,         # $TAB_COMPLETE ? or SetTabComplete as a state? or postback?
	{},            # $GEOMETRY
    ];

    bless $self, (ref $class || $class);
    $self->init(@_);
    return $self;

}

sub init {
    my $self = shift;
    my %opts = @_;

    $self->debug("start");

    #
    # check for vital init args / configs
    #
    foreach my $opt_key (qw(
			       Alias
			       OutBuffers
			       TitleBar TitleBarFormat TitleBarFields
			       StatusBar StatusBarFormat StatusBarFields
			       EditHeight
		       ))
    {
	$self->[$PARAMS]->{$opt_key} = delete $opts{$opt_key} if defined $opts{$opt_key};
    }

    # DEBUG, TRACE, DEFAULT
    foreach my $cap_key (qw( Debug Trace Default )) {
	$self->[$PARAMS]->{uc($cap_key)} = ( delete $opts{$cap_key} || 0 );
    }

    # NOTE: unknown constructor args will fire error events once we've started the session.
    foreach my $leftover ( keys %opts ) {
	my $value = $opts{$leftover};
	warn ref($self).": unknown constructor param: '$leftover' => '$value'\n";
    }

    $self->debug("defaults");

    # defaults
    $self->[$PARAMS]->{Alias} || 'chatterm';
    # 0, num, or default to 1
    if (! $self->[$PARAMS]{OutBuffers} ) {
	$self->[$PARAMS]{OutBuffers} = ['system'];
    }

    $self->[$GEOMETRY]{StatusHeight} = defined $self->[$PARAMS]{StatusBar} ?  $self->[$PARAMS]{StatusBar} : 1;
    $self->[$GEOMETRY]{TitleHeight}  = defined $self->[$PARAMS]{TitleBar}  ?  $self->[$PARAMS]{TitleBar}  : 1;
    $self->[$GEOMETRY]{EditHeight}   = $self->[$PARAMS]{EditHeight} || 1;
    $self->[$GEOMETRY]{OutputHeight} = 0;

    #
    # create the main session
    #
    $self->debug("init main session");
    $self->[$TERM] = POE::Session->create(
	inline_states => {},
	object_states => [
	    $self => {
		_start => 'init_screen',
		SendUserInput => 'SendInput',
		SendError     => 'SendInput',

	    },
	    $self => [qw(
			    _stop _got_stderr _got_curses_input
			    add_to_heap_cleanup add_to_refcount_cleanup
			    SendToBuffer SendToCurrent SendToBufferAndCurrent
			    LaunchBuffer ShutdownBuffer
			    UpdateTitleFormat UpdateTitle UpdateStatusFormat UpdateStatus
			    ExpandEdit ShrinkEdit
			    setPallet
		    )],
	],
	options => { debug => $self->[$PARAMS]{DEBUG},  trace => $self->[$PARAMS]{TRACE},  default => $self->[$PARAMS]{DEFAULT}, },
	heap => { cleanup => [] },
    );

    # Pipe STDERR to a readable handle.
    my $read_stderr = gensym();
    pipe($read_stderr, STDERR) || do {
	open STDERR, ">&=2";
	die "can't pipe STDERR: $!";
    };

    $self->[$TERM]->get_heap()->{stderr_reader} = POE::Wheel::ReadWrite->new
    ( Handle      => $read_stderr,
      Filter      => POE::Filter::Line->new(),
      Driver      => POE::Driver::SysRW->new(),
      InputEvent  => "got_stderr",
    );
    POE::Kernel->post( $self->[$TERM]->ID() => 'add_to_heap_cleanup' => 'stderr_reader' );

    $self->debug("done");
}

#
# CLEANUP CLEANUP
#

# from the heap
sub add_to_heap_cleanup {
    my ($self,$H,@heap_keys) = @_[OBJECT,HEAP,ARG0..$#_];
    $self->debug("pushing '@heap_keys' onto heap cleanup list");
    push @{ $H->{cleanup} }, @heap_keys;
    $self->debug("done");
    return;
}
sub cleanup_heap {
    my ($self,$H) = @_[OBJECT,HEAP];
    $self->debug("cleaning up heap");
    my @list = List::MoreUtils::uniq @{$H->{cleanup}};
    delete $H->{$_} foreach @list;
    $self->debug("done");
    return;
}

# from the refcounts
sub add_to_refcount_cleanup {
    my ($self,$H,@pairs) = @_[OBJECT,HEAP,ARG0..$#_];
    $self->debug("pushing '@pairs' onto refcount cleanup list");
    push @{$H->{refcounts}}, @pairs;
    return;
}
sub cleanup_refcounts {
    my ( $self,$H,$K ) = @_[OBJECT,HEAP,KERNEL];
    $self->debug("decrementing refcounts");
    my @list = List::MoreUtils::uniq @{$H->{refcounts}};
    $K->refcount_decrement(@$_) foreach @list;
    $self->debug("done");
    return;
}

# shutdown the Term::Chat session
sub _stop {
    my ($self,$K,$H) = @_[OBJECT,KERNEL,HEAP];
    $self->debug("shutting down!");
    endwin();
    $K->yield('cleanup_refcounts');
    $K->yield('cleanup_heap');
    $K->alias_remove($self->[$PARAMS]{Alias});
    $self->debug("done");
};

sub shutdown {
    $_[KERNEL]->yield('_stop');
}

# and for not so clean shutdowns...
sub sigDIE {
    my ($self,$K,$sig,$ex) = @_[OBJECT,ARG0,ARG1];
    $self->debug("Dying with following signal/exception:", $sig, $ex);
    $K->sig_handled();
    if ( $ex->{source_session} ne $_[SESSION] ) {
	$K->signal( $ex->{source_session}, 'DIE', $sig, $ex );
    }
}

#
# creating term objects, initializing terminal, calculating dimensions
#
sub init_screen {
    my ($self,$K,$H,$SESSION) = @_[OBJECT,KERNEL,HEAP,SESSION];
    $self->debug("start");

    # setup
    $K->sig( DIE => "sigDIE" );

    $self->debug("Curses setup");
    $H->{console} = POE::Wheel::Curses->new( InputEvent => '_got_curses_input' );
    $K->yield(add_to_heap_cleanup => 'console');

    $K->alias_set($self->[$PARAMS]{Alias});
    use_default_colors();
    my $old_mouse_events = 0;
    mousemask(0, $old_mouse_events);

    #
    # Default Palette
    #
    $self->debug("Palette setup");
    $self->set_palette(
        stderr_bullet => "bright white",
        stderr_text   => "bright yellow",
        statcolor     => "green on black",
        ncolor        => "white",
        status_bar    => "bright cyan on blue",
        title_bar     => "bright white on blue",
    );

    $self->debug("calc win size");
    $self->calc_win_size();

    # BUILD WINDOWS
    $self->debug("create windows");
    $self->_init_windows;

    $self->debug("create screen elements");
    # term window controller objects
    $self->_init_meta_data;


    $self->debug("SAFETY: shutdown in 20 seconds");
    $K->delay("_stop", 20);

    $self->debug("done");
    return;
}

sub calc_win_size {
    my $self = shift;
    $self->debug("start");

    # what do we know?
    my $geometry = $self->[$GEOMETRY];

    @{ $geometry }{qw(COLS LINES)} = GetTerminalSize();
    $self->trace("LINES (env/curses): " . $geometry->{LINES}.'/'.LINES() . ", COLS: " . $geometry->{COLS}.'/'.COLS() );

    # get the height of the output screen
    $geometry->{OutputHeight} = $geometry->{LINES} - ( List::Util::sum @{ $geometry }{qw(TitleHeight StatusHeight EditHeight)} );

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

    $self->debug("Geometry:", $geometry);
    $self->debug("done");

    return;
}


#
# Color!
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

# public event version of set_palette
sub setPallet {
    my $self = $_[OBJECT];
    my %params = @_[ARG0..$#_];
    $self->set_palette( %params );
}

sub set_palette {
    my ($self,%params) = @_;
    $self->debug("start");

    for my $color_name (keys %params) {
	$self->debug("parsing $color_name");

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
        if ( exists $self->[$PALETTE]{$color_name} )
	{
            my $old_color_number = $self->[$PALETTE]{$color_name}[$PAL_NUMBER];
            init_pair($old_color_number, $foreground, $background);
            $self->[$PALETTE]->{$color_name}->[$PAL_PAIR] = COLOR_PAIR($old_color_number) | $attributes;
        }
        else
	{
            my $new_color_number = ++$self->[$PAL_NUM_SEQ];
            init_pair($new_color_number, $foreground, $background);
            $self->[$PALETTE]->{$color_name} = [
		COLOR_PAIR($new_color_number) | $attributes, # $PAL_PAIR
		$new_color_number,                           # $PAL_NUMBER
		$description,                                # $PAL_DESC
	    ];
        }
    }
    $self->debug("done");
}


#
# create the windows first
#
# this create each of the meta-data structures that keep track
# of scrolling, editing, display states, etc
# - title and status
# - edit
# - buffer meta for each buffer created at start
#   - make re-usable or spawning
#
sub _init_meta_data {
    my ($self) = @_;
    $self->debug("start");

    my $debug_callback = sub { $self->debug(@_) };

    # if we've got a status bar, make that
    if ( $self->[$WIN_STATUS] ) {
    	$self->debug("making StatusBar for status bar");
    	$self->[$STATUS] = POE::Component::Term::Chat::StatusBar->new(
    	    Format  => $self->[$PARAMS]{StatusFormat},
    	    Fields  => $self->[$PARAMS]{StatusFields},
    	    Height  => $self->[$GEOMETRY]{StatusHeight},
    	    Width   => $self->[$GEOMETRY]{COLS},
    	    Window  => $self->[$WIN_STATUS],
    	    Palette => $self->[$PALETTE],
    	    DefaultColor => 'status_bar',
	    DebugCallback => $debug_callback,
    	);
    }

    # same for title bar
    if ( $self->[$WIN_TITLE] ) {
    	$self->debug("making StatusBar for title bar");
    	$self->[$TITLE] = POE::Component::Term::Chat::StatusBar->new(
    	    Format => $self->[$PARAMS]{TitleFormat},
    	    Fields => $self->[$PARAMS]{TitleFields},
    	    Window => $self->[$WIN_TITLE],
    	    Height  => $self->[$GEOMETRY]{TitleHeight},
    	    Width   => $self->[$GEOMETRY]{COLS},
    	    Palette => $self->[$PALETTE],
    	    DefaultColor => 'title_bar',
	    DebugCallback => $debug_callback,
    	);
    }

    # # and for edit...
    # if ( $self->[$WIN_EDIT] ) {
    # 	$self->debug("making EditWindow");
    # 	$self->[$EDIT] = POE::Component::Term::Chat::EditWindow->new(
    # 	    Window  => $self->[$WIN_EDIT],
    # 	    Palette => $self->[$PALETTE],
    # 	    DefaultColor => 'ncolor',
    # 	    Height  => $self->[$GEOMETRY]{EditHeight},
    # 	    Width   => $self->[$GEOMETRY]{COLS},
    # 	    ## XXX: add to component constructor list and defaults:
    # 	    # HistorySize
    # 	    # Prompt
    # 	    DebugCallback => $debug_callback,
    # 	);
    # }

    # # and one for each output
    # if ( $self->[$WIN_OUT] ) {
    # 	foreach my $outbuf ( @{ $self->[$PARAMS]{OutBuffers} } ) {
    # 	    $self->debug("making OutBuffer:$outbuf");
    # 	    push @{$self->[$OUT_BUFFERS]}, POE::Component::Term::Chat::OutputWindow->new(
    # 		Name    => $outbuf,
    # 		Window  => $self->[$WIN_OUT],
    # 		Palette => $self->[$PALETTE],
    # 		DefaultColor => 'ncolor',
    # 		Height  => $self->[$GEOMETRY]{OutputHeight},
    # 		Width   => $self->[$GEOMETRY]{COLS},
    # 		DebugCallback => $debug_callback,
    # 	    );
    # 	    if ( ! $self->[$CUR_BUFFER] ) {
    # 		$self->[$CUR_BUFFER] = $self->[$OUT_BUFFERS][$#{$self->[$OUT_BUFFERS]}];
    # 	    }
    # 	}
    # }

    $self->debug("refreshing screen");
    foreach my $window ( grep { defined } @{$self}[$TITLE, $STATUS, $EDIT, $CUR_BUFFER] ) {
	$self->debug("refreshing: ", $window);
	$window->refresh();
    }

    $self->debug("done");
    return;
}

# start the window for status bar
sub _init_windows {
    my $self = shift;
    $self->debug("start");

    if ( $self->[$GEOMETRY]{StatusHeight} ) {
	$self->debug("status win");
	$self->[$WIN_STATUS] = newwin(@{ $self->[$GEOMETRY] }{qw(StatusHeight COLS StatusBegin)},0);
    }

    if ( $self->[$GEOMETRY]{TitleHeight} ) {
	$self->debug("title win");
	$self->[$WIN_TITLE] = newwin(@{ $self->[$GEOMETRY] }{qw(TitleHeight COLS TitleBegin)},0);
    }

    if ( $self->[$GEOMETRY]{EditHeight} ) {
	$self->debug("edit win");
	$self->[$WIN_EDIT] = newwin(@{ $self->[$GEOMETRY] }{qw(EditHeight COLS EditBegin)},0);
    }

    if ( $self->[$GEOMETRY]{OutputHeight} ) {
	$self->debug("outbuffer win");
	$self->[$WIN_OUT] = newwin(@{ $self->[$GEOMETRY] }{qw(OutputHeight COLS OutputBegin)},0);
    }

    $self->debug("done");
    return;
}

#
# Register sender's input/err handlers
#

sub SendInput {
    my ($self,$state,$SENDER,$H,$K,$sender_input_state) = @_[OBJECT,STATE,SENDER,HEAP,KERNEL,ARG0];
    $self->debug("start");
    return unless $sender_input_state;

    my $postback_name = substr( $state, 4 ); # UserInput or ErrorInput
    my $session_id_name = $postback_name."SessionID";
    $H->{$postback_name} = $SENDER->postback( $sender_input_state );
    $H->{$session_id_name} = $SENDER->ID();
    my $refcount_args = [$H->{$session_id_name}, $postback_name.'Link'];
    $K->refcount_increment(@$refcount_args);
    $K->yield( add_to_refcount_cleanup => $refcount_args);
    $K->yield( add_to_heap_cleanup => $postback_name, $session_id_name );

    $self->debug("sending '$state' to session $H->{$session_id_name}, event:$sender_input_state");
    $self->debug("done");
    return;
}

#
# Output Buffers
#

sub SendToCurrent {
    # find the current output buffer, add to its buffer
    $_[OBJECT]->debug("called with args: " . join('|', map { qq('$_') } @_[ARG0..$#_]));
}

sub SendToBuffer {
    # send output to a buffer whether it's current or not
    $_[OBJECT]->debug("called with args: " . join('|', map { qq('$_') } @_[ARG0..$#_]));
}

sub SendToBufferAndCurrent {
    # send to both specific and current if they're not the same
    $_[OBJECT]->debug("called with args: " . join('|', map { qq('$_') } @_[ARG0..$#_]));
}

sub LaunchBuffer {
    # create a new output buffer to attach to the output window
}

sub ShutdownBuffer {
    # remove a buffer from output buffers
}

#
# Update status bars
#

sub UpdateStatusFormat {
    # update the format of the status bar
}

sub UpdateStatus {
    # update the status bar fields and refresh
}

sub UpdateTitleFormat {
    # update the format of the title bar
}

sub UpdateTitle {
    # update the fields in the title bar
}

#
# Edit window
#

sub ExpandEdit {
    # grow the edit window by one line and redraw the screen
}
sub ShrinkEdit {
    # shrink the edit window by one line (if possible) and redraw
}


#
# Got Key: what do we do with it, mmm?
#
sub _got_curses_input {
    my ($self,$H,$K,$input) = @_[OBJECT,HEAP,KERNEL,ARG0];
    # this would be a good place to call on a library of key map library,
    # something mapping keys to internal/external events?
    $self->debug("sending input from curses to handler session: '$input'");
    if ( $H->{UserInput} ) {
	$H->{UserInput}->($input);
    }
    # for the time being, log it
    $K->yield('_log_curses_input',$input);
    $self->debug("done");
    return;
}

sub _got_stderr {
    my ($self,$H,$input) = @_[OBJECT,HEAP,ARG0];
    $self->debug("sending input from error to handler session: '$input'");
    if ( $H->{Error} ) {
	$H->{Error}->($input);
    }
    $self->debug("done");
}

sub debug {
    my ($self,@msgs) = @_;
    if ( $self->[$PARAMS]{DEBUG} ) {
	$self->debug_handler('DEBUG',@msgs);
    }
}

sub trace {
    my ($self,@msgs) = @_;
    if ( $self->[$PARAMS]{TRACE} ) {
	$self->debug_handler('TRACE',@msgs);
    }
}

sub debug_handler {
    my ($self,$type,@inputs) = @_;
    my $caller = ( caller(2) )[3];
    open(LOG,'>> ./term_chat.log') || die "Could not open log file: $!";

    foreach my $input ( @inputs ) {
	if ( ref($input) ) {
	    print LOG "[$type] $caller: $input:\n" . Data::Dumper::Dumper($input) ."\n";
	} else {
	    print LOG "[$type] $caller: $input\n";
	}
    }

    close(LOG);
}

sub DESTROY {
    my ($self,$K) = @_[OBJECT];
    endwin();
    $K->yield('_stop');
}


1;
