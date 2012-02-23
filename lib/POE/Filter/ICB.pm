package POE::Filter::ICB;

use strict;
use base qw(POE::Filter);

sub new {
    my $type = shift;
    my $self = { @_ };
    $self->{uc $_} = delete $self->{$_} for keys %{ $self };
    $self->{BUFFER} = [];
    bless $self,$type;
    $self->debug("\ninitializing POE::Filter::ICB");
    return $self;
}

sub debug {
    my ($self,$msg) = @_;
    $self->log_to_file($msg) if $self->{DEBUG};
}
sub debug_dump {
    my ($self,$msg,$dump) = @_;
    require Data::Dumper;
    if ( $self->{DEBUG} ) {
        $self->log_to_file($msg);
        $self->log_to_file(Data::Dumper::Dumper($dump));
    }
}

sub get_one_start {
    my ($self,$rawlines) = @_;
    $self->debug("inside get_one_start, pushing " . scalar(@$rawlines) . " rawlines onto buffer");
    push @{ $self->{BUFFER} }, $_ for @$rawlines;
}

sub get_one {
    my $self = shift;
    my $events = [];

    $self->debug("get_one: begin");
    if ( my $raw_line = shift( @{ $self->{BUFFER} } )) {
        $self->debug_dump("get_one: raw_line from BUFFER",$raw_line);
        $events = $self->parse_raw_line($raw_line);
    }
    $self->debug("get_one: returning " .scalar(@$events). " event lines");

    return $events;
}

sub get {
    my ($self,$raw_lines) = @_;
    my $events = [];

    $self->debug("inside get");
    foreach my $raw_line ( @$raw_lines ) {
        my $parsed = $self->parse_raw_line($raw_line);
        push @$events, @$parsed;
    }
    $self->debug("get: returning " .scalar(@$events). " event lines");
    return $events;
}

sub parse_raw_line {
    my ($self,$raw_line) = @_;
    my @parsed;
    while ( $raw_line ) {
        # take the first char, should be the length
        my $len_byte = substr($raw_line,0,1,'');
        my $len = ord($len_byte);
        if ( $len > length($raw_line) ) {
            self->debug("parse_raw_line: raw_line incomplete, shifting back onto BUFFER");
            my $leftover = $len_byte.$raw_line;
            unshift @{ $self->{BUFFER} }, $leftover;
            undef($raw_line);
        }
        $self->debug("parse_raw_line: splicing first $len bytes off raw_line");
        # take the next len ascii chars
        my $msg = substr($raw_line,0,$len,'');
        $self->debug("parse_raw_line: pushing '$msg' onto parsed");
        push @parsed, $msg;
        # do it again until there's no more $rawline
    }
    return \@parsed;
}


sub get_pending {
    my $self = shift;
    $self->debug("in get_pending, " . scalar(@{$self->{BUFFER}}) . " remaining items in BUFFER");
    return $self->{BUFFER};
}

sub put {
    my ($self,$events) = @_;

    $self->debug("put: begin");
    my $raw_lines = [];
    foreach my $event ( @$events ) {
        $self->debug_dump("put: starting with single event line:", $event);
        my $raw_line = chr(length($event)).$event;
        $self->debug_dump("put: pushing single raw_line:", $raw_line);
        push @$raw_lines, $raw_line;
    }
    $self->debug_dump("put: returning", $raw_lines);
    return $raw_lines;
}

sub clone {
    my $self = shift;
    my $nself = {};
    $nself->{$_} = $self->{$_} for keys %$self;
    $nself->{BUFFER} = [];
    return bless $nself, ref $self;
}

### client->server packet types
# login:          a        fields: none
# open msg:       b        fields: nick, message
# personal msg:   c        fields: nick, message
# status msg:     d        fields: category, message
# error msg:      e        fields: msg
# important msg:  f        fields: category, message
# exit msg:       g        fields: [none]
# command output: i        fields: output type, output*, messageID
# protocol:       j        fields: protocol level, host id, client id
# beep:           k        fields: nick
# ping:           l        fields: msgID
# pong:           m        fields: msgID
# no-op:          n        fields: [none]

sub log_to_file {
    my ($self,$msg) = @_;
    my $log_file = "./log_file";
    open(FH,">>log_file") || die "Could not open log file ($log_file): $!";
    print FH "$msg\n";
    close(FH);
}

1;
