package POE::Component::Term::Chat::Window;

use strict;
use Exporter qw(import);
use Curses;
use Readonly;
# use vars qw($PAL_PAIR $PAL_NUMBER $PAL_DESC);

Readonly::Scalar our $PAL_PAIR   => 0;
Readonly::Scalar our $PAL_NUMBER => 1;
Readonly::Scalar our $PAL_DESC   => 2;
our @EXPORT = qw($PAL_PAIR $PAL_NUMBER $PAL_DESC);

sub new {
    my $class = shift;
    my %opts = @_;

    my $self = bless
    {
	# base attributes
	Window  => undef,
	Height  => '',
	Width   => '',
	Palette => undef,
	Color   => undef,
	DebugCallback => undef,
	# and subclass...
	%opts,
    }, (ref($class) || $class);

    return $self;
}

sub debug {
    my ($self,@msgs) = @_;
    $self->{DebugCallback} && $self->{DebugCallback}->(@msgs);
}

1;
