#!/usr/bin/perl

use strict;
use lib qw(../lib);
use POE qw(Component::Term::Chat);

our $CHAT = 'chatterm';  # alias for chat term
our $SYSTEM  = 'system';
our $CHANNEL = 'channel';

POE::Session->create(
    inline_states => {
	_start => \&_start_term,
	_stop  => sub { $_[KERNEL]->call($CHAT => '_stop'); $_[HEAP]->{term} = undef; exit(); },
	_default => sub { print STDERR $_[ARG0]." CALLED WITH ARGS: " . join(' | ', @{@_[ARG1]} ); return 0; },
	handle_user_input => \&handle_user_input,
	handle_error_input => \&handle_error_input,
    },
    options => { default => 1, debug => 1, trace => 1 },
);
POE::Kernel->run();




#
# initially: handle the constructor args, pass back the session
# - the session should have the correct alias
# - the session should correctly assign user input to the session's handler
#
# So let's see. This should create a fullscreen term with 4 windows and 2 buffers:
# - title bar with format, 1 line high
# - status bar with format, 1 line high
# - edit buffer is 1 high (but should expand for more text and shrink when it goes down)
# - output window takes up rest of the space
# - should be able to create palettes, and use them
#
# there should be 2 output buffers: system, and channel
# - when switching between them, each should carry it's own text
# - when a buffer has the window, it should either be updating or paging,
# - when a buffer is background, it's buffer should still be updating
# - each should maintain its own current position
# - does each carry its own command history?
#
# - APPLICATION SHOULD BE ABLE TO SPAWN ANOTHER AND FEED IT OUTPUT
#
# the edit window:
# - should be able to output keys as they're typed, and pass the line
#   off to user input once the line's been accepted
# - should be able to intercept ctrl-keys and arrows
# - should be able to use ctrl-a and ctrl-e to go beginning to end of current buffer
# - should be able to ctrl-k to yank from the cursor to the end
#   - should be able to paste it back with ctrl-y
# - should be able to put keys down at the beginning/middle/end of current buffer and redraw correctly
# - should be able to go up or down if the edit field's more than 1 line high
#   - or at least scroll the line up and down, and keep the input buffer straight
# - should be able to account for cursor and cursor length
#
# (i don't use IRC, but output buffer should probably be able to render mIRC colors?)
#
# ARCHITECTURE:
# -------------
# - POE::Component::Term::Chat handles I/O, manages windows, redraws whole window maybe?
# - POE::Component::Term::Chat::OutputWindow is the output buffer
#   - one of these per buffer (with its own command-history?),
#   - each keeps its own mode (page,stream) and position, holds its own scrollback buffer
# - POE::Component::Term::Chat::StatusBar is the title and status bar
# - POE::Component::Term::Chat::EditWindow is the edit window
#

sub _start_term {
    my ($H,$K,$S) = @_[HEAP,KERNEL,SESSION];

    print STDERR "I AM SESSION: " . $S->ID . "\n";

    $H->{term} = POE::Component::Term::Chat->new(
	# set up
	Alias => $CHAT,
	# start with the buffers
	OutBuffers => [$SYSTEM,$CHANNEL],

	# layout params
	TitleBar        => 1,
	TitleBarFormat  => ' POE SCREEN TEST: [% funny phrase %]',
	StatusBar       => 1,
	StatusBarFormat => ' [% host %]|[% group %]|[% user %] ',

	Debug => 1, Trace => 1, Default => 1,
    );

    $K->post($CHAT => SendUserInput => 'handle_user_input');
    $K->post($CHAT => SendError     => 'handle_error_input');

    $K->delay('_stop',10);

    return;
}

sub handle_user_input {
    my ($H,$K,$input) = @_;
    # taking a line from the chat term's edit window, and putting it on the screen:

    $H->{term}->debug("in handle_user_input");

    if ( $input =~ /^\/current\b/ ) {
	$K->post($CHAT => SendToCurrent  => "[SendToCurrent]: $input");
    } elsif ( $input =~ /^\/current\b/ ) {
	$K->post($CHAT => SendToBuffer  => $SYSTEM, "[SendToBuffer(system)]: $input");
    } else {
	$K->post($CHAT => SendToBufferAndCurrent  => $SYSTEM, "[SendToBufferAndCurrent(system)]: $input");
    }
    return;
}

sub handle_error_input {
    my ($H,$K,$input) = @_;

    $H->{term}->debug("in handle_error_input");

    # taking error input and.. what?
    $K->post($CHAT => SendToBufferAndCurrent  => $SYSTEM, "[SendToBufferAndCurrent(system)]: $input");
    return;
}
