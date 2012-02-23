package POE::Component::Term::Chat::StatusBar;

use strict;
use POE::Component::Term::Chat::Window;
use base qw(POE::Component::Term::Chat::Window);
use Readonly;

sub new {
    my $class = shift;
    my %opts = @_;

    my $self = $class->SUPER::new(
	# specific to status bar
	Format => '',
	Fields => {},
	Text   => '',
    );

    $self->init(%opts);
    return $self;

}

sub init {
    my ($self,%opts) = @_;

    # load init args
    foreach my $key ( qw(Format Window Height Width Palette DebugCallback) ) {
	$self->{$key} = delete $opts{$key};
    }
    my $fields = delete $opts{Fields};
    foreach my $f ( %$fields ) {
	$self->{Fields}{$f} = $fields->{$f};
    }
    $self->{Color} = (delete $opts{DefaultColor} || 'ncolor');

    if ( my @leftovers = keys %opts ) {
	warn "Unrecognized constructor: '$_' => '$opts{$_}'" foreach @leftovers;
    }

}

sub update_format {
    my ($self,$format) = @_;
    $self->{Format} = $format;
}

sub update_fields {
    my ($self,%fields) = @_;
    while ( my ($name,$val) = each %fields ) {
	$self->{Fields}{$name} = $val;
    }
}

sub refresh {
    my ($self) = @_;
    $self->debug("setting format");
    my $text = $self->{Format};
    $self->debug("filling in fields");
    foreach my $field ( $self->{Fields} ) {
	my $val = $self->{Fields}{$field};
	$text =~ s/\[\%\s*$field\s*\%\]/$val/g;
    }
    $self->{Text} = $text;
    $self->debug("refreshing window");
    $self->refresh_window();
}

sub refresh_window {
    my ($self) = @_;
    return if ! ( my $win = $self->{Window} );

    if ( $win ) {
	my $width = $self->{Width};
	my $status_text = $self->{Text};
	my $status_fill = ' ' x ( $width - length($status_text) );
	$status_text .= $status_fill;
	$self->debug("setting width: $width, text: '$status_text'");

#	$self->debug("redrawing window with color pair:" . $self->{Palette}->{ $self->{Color} }->[ $PAL_PAIR ]);
#	$win->attrset($self->{Palette}->{ $self->{Color} }->[ $PAL_PAIR ]);
#	$self->debug("moving to 0,0");
#	$win->move(0,0);
#	$self->debug("adding string: '$status_text'");
#	$win->addstr($status_text);
#	$self->debug("clear to end of line");
#	$win->clrtoeol();
#	$self->debug("refresh");
#	$win->noutrefresh();
	$self->debug("doupdate");
#	doupdate();
    } else {
	$self->debug("didn't have a window!");
	die;
    }
    $self->debug("done");
    return;
}

1;
