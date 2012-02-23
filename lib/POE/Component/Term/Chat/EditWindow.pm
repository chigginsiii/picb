package POE::Component::Term::Chat::EditWindow;

use strict;
use Curses;
use POE::Component::Term::Chat::Window;
use base 'POE::Component::Term::Chat::Window';

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(
	# settable by constructor:
	HistorySize     => 50,    # lines of history
	Prompt          => '',    # set by constructor or set_cursor()
	# managed by Chat::EditWindow
	HistoryIndex    => -1,    # current history index
	CommandHistory  => [ ],   # actual history buffer
	Data            => "",    # data buffer
	DataSave        => "",    # pull data in data buffer (for instance when we're cycling through history
	Cursor          => 0,     # cursor position
	Cursor_Save     => 0,     # cursor position of Data_Save
	EditPosition    => 0,     # NOTE: NEED TO NAIL THIS
	PromptSize      => 0,     # size of cursor, this should be set by set_cursor()
	KillBuffer      => '',    # last yanked item
	UpdateScreen    => 1,     # set this to 0 when paging through scrollback
    );
    $self->init(@_);
    return $self;
}

sub init {
    my ($self,%opts) = @_;

    foreach my $key ( qw(
			    Format Window Height Width Palette
			    HistorySize Prompt
		    ) )
    {
	$self->{$key} = delete $opts{$key};
    }
    $self->{Color} = (delete $opts{DefaultColor} || 'ncolor');

    if ( my @leftovers = keys %opts ) {
	warn "Unrecognized constructor: '$_' => '$opts{$_}'" foreach @leftovers;
    }

}

sub refresh {
    my $self = shift;
    my $win = $self->{Window};
    if ( $win ) {
	$win->erase();
	$win->noutrefresh();
	$win->attrset($self->{Palette}->{ $self->{Color} }->[ $PAL_PAIR ]);
	$win->move(0,0);
	$win->clrtoeol();
	$win->noutrefresh();
	doupdate();
    }
}

1;
