package POE::Component::Term::Chat::OutputWindow;

use strict;
use Curses;
use POE::Component::Term::Chat::Window;
use base qw(POE::Component::Term::Chat::Window);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(
	# set from constructors
	Name          => '',
	BufferSize    => 0,
	# managed internally
	Buffer        => [],
	BufferRow     => '',
	BufferFirst   => 0,
	BufferLast    => 0,
	BufferVisible => 0,
	ScrolledLines => 0,
    );
    $self->init(@_);
    return $self;
}

sub init {
    my ($self,%opts) = @_;

    # load init args
    foreach my $key (qw(
			   Name
			   Format Window Height Width Palette
			   BufferSize
		   ))
    {
	$self->{$key} = delete $opts{$key};
    }
    $self->{Color} = (delete $opts{DefaultColor} || 'ncolor');

    if ( my @leftovers = keys %opts ) {
	warn "Unrecognized constructor: '$_' => '$opts{$_}'" foreach @leftovers;
    }

    #
    # Defaults
    #
    $self->{BufferSize} ||= 100;

    #
    # setup the buffer (do this on resize as well...
    #
    $self->setup_buffer_state();
    $self->setup_window();
}

sub setup_buffer_state {
    my $self = shift;

    # stupid buffer tricks:
    $self->{BufferLast}    = $self->{BufferSize} - 1; # idx of last row of buffer
    $self->{BufferFirst}   = $self->{Height} - 1;     # index of first line of the buffer?
    $self->{BufferVisible} = $self->{Height} - 1;     # index of first visible line of buffer

    $self->{BufferRow} = $self->{BufferLast};         # idx of our current row
    $self->{Buffer} = [("") x $self->{BufferSize}];   # line buffer = arrayref with one blank line all the way across...

}

sub setup_window {
    my $self = shift;

    $self->{Window}->bkgd( $self->{Palette}->{$self->{Color}}->[ $PAL_PAIR ] );
    $self->{Window}->erase();
    $self->{Window}->noutrefresh();

}

sub refresh {
    my $self = shift;

    my $win = $self->{Window};
    die "No current window!" unless $win->{Window};

    #
    # this is a reference back to manager's window
    # so we'll depend upon manager to deal with
    # resizing and updating our geometry
    #
    #$win->{window} = newwin(
    #$self->{Height},
    #	$self->{Width},
    #	$self->{OutputBegin},
    #	0
    #);

    $self->{BufferFirst}   = $self->{Height} - 1;
    $self->{BufferVisible} = $self->{Height} - 1;

    $self->{Window}->bkgd( $self->{Palette}->{ $self->{Color} }->[ $PAL_PAIR ] );
    $self->{Window}->erase();
    $self->{Window}->noutrefresh();

    $self->refresh_window();
    return;
}

sub refresh_window {
    my $self = shift;

    my $screen = $self->{Window} || return;

    #
    # last visible buffer row is above the end, we're scrolling
    # subtract the number of scrolled lines to compensate
    #
    if ($self->{BufferRow} < $self->{BufferLast}) {
        $self->{BufferRow} -= $self->{ScrolledLines};
    }

    #
    # current row can't be less than the beginning, or more than the end
    #
    if ($self->{BufferRow} < $self->{BufferFirst}) {
        $self->{BufferRow} = $self->{BufferFirst};
    } elsif ($self->{BufferRow} > $self->{BufferLast}) {
        $self->{BufferRow} = $self->{BufferLast};
    }

    #
    # we're all compensated, go ahead and draw it from here:
    #
    $screen->erase();
    $screen->noutrefresh();
    $self->{Scrolled_Lines} = 0;

    # screen_y is the actual line of the window we're on;
    # buffer_y is the index 
    my $screen_y = 0;
    my $buffer_y = $self->{BufferRow} - $self->{BufferVisible};

    while ( $screen_y < $self->{Height} )
    {

        $screen->move($screen_y, 0);
        $screen->clrtoeol();
        $screen->noutrefresh();

        if ( $buffer_y < 0 || $buffer_y > $self->{BufferLast} ) {
	    next;
	}

        my $line = $self->{Buffer}[$buffer_y];
        my $column = 1;
        while (length $line) {
            while ($line =~ s/^\0\(([^)]+)\)//) {
                my $cmd = $1;
                if ($cmd =~ /(?:blink|bold|underline)_(on|off)/) {
		    my $attr = $1;
		    my $val  = $2;

		    my $attr_set = {
			blink => {
			    on  => sub {  $screen->attron(A_BLINK) },
			    off => sub {  $screen->attroff(A_BLINK) },
			},
			bold =>  {
			    on  => sub {  $screen->attron(A_BOLD) },
			    off => sub {  $screen->attroff(A_BOLD) },
			},
			underline =>  {
			    on  => sub {  $screen->attron(A_BOLD) },
			    off => sub {  $screen->attroff(A_BOLD) },
			}
		    }->{$attr}{$val};
		    if ( $attr_set ) {
			$attr_set->();
			$screen->noutrefresh();
		    }
		}
                else
		{
                    $screen->attrset($self->{Palette}->{$cmd}->[ $PAL_PAIR ]);
                    $screen->noutrefresh();
                }
            }

	    if ($line =~ s/^([^\0]+)//x)
	    {
		my $word = $1;
		my $new_col_len = $column + length($word);
		my $width = $self->{Width};
                next if $column >= $width;

                if ( $new_col_len > $width )
		{
		    my $truncate_pos = length($word) - ( $new_col_len - $width ) - 1;
                    my $leftover = substr($word, $truncate_pos) = '';
		    # something should be done with the leftover!
                }
		$screen->addstr($word);
                $column += length($word);
                $screen->noutrefresh();
            }
        }

        $screen->attrset($self->{Palette}->{$self->{Color} }->[ $PAL_PAIR ]);
        $screen->noutrefresh();
        $screen->clrtoeol();
        $screen->noutrefresh();
    }
    continue
    {
        $screen_y++;
        $buffer_y++;
	# $self->trace("increment screen/buffer: $screen_y/$buffer_y");
    }
    doupdate();
    return;

}


1;
