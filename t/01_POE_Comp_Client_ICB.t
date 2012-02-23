#!/usr/bin/perl

use lib qw(../lib);
use strict;
use Test::More qw(no_plan);
use Data::Dumper qw(Dumper);
BEGIN {
    use_ok('POE');
    use_ok('POE::Component::Client::ICB');
}

# start a session that can run through the protocol and test
POE::Session->create(
    inline_states => {
	_start      => \&setup_client,
	_stop       => \&shutdown_client,
	_default    => \&default,

	run_tests   => \&run_tests,
	login       => sub {
	    my ($h,$k) = @_[HEAP,KERNEL];
	    $h->{client}->debug("calling login on $h->{alias}");
	    $k->call( $h->{alias}, 'login' ) if ( !$h->{logged_in} );
	},
	sendaway    => sub { $_[KERNEL]->call( $_[HEAP]->{alias}, 'noaway') },

	# states we pick up from Client::ICB
	icb_client_connected   => \&h_client_connected,
	icb_client_error       => \&error,
	icb_client_protocol    => \&h_protocol,
	icb_client_login_ok    => \&h_login_ok,
	icb_client_cmdout      => \&h_cmdout,
	icb_client_status      => \&h_status,

    },
    options => { default => 1 },
    heap => {
	tests => {},
    },
);

POE::Kernel->run();

sub setup_client {
    my ($H,$K,$S) = @_[HEAP,KERNEL,SESSION];
    my $icb_client = 'icb_client';

    $H->{client} = POE::Component::Client::ICB->new(
	Alias       => $icb_client,
	RemoteHost  => 'default.icb.net',
	RemotePort  => '7326',
	Nick        => 'chigpoet',
	Group       => 'testpoec',

	Debug   => 1,
	Trace   => 0,
	Default => 1,
	# LoginGroupStatus => 'mil im 0 b 0',

	# test the leftover error condition:
	BogusParam => "Boooo-o-o-o-o-ogus!",
    );

    $H->{alias} = $icb_client;
    isa_ok( $H->{client}, 'POE::Component::Client::ICB' );

    $H->{client}->debug("registering this client as listener: " . $S->ID);
    $K->post($H->{alias}, 'register_session');
}

sub shutdown_client {
    my ($K,$H) = @_[KERNEL,HEAP];
    $K->call($H->{alias}, 'shutdown');
    $H->{client} = undef;
}

sub run_tests {
    my ($K,$H) = @_[KERNEL,HEAP];

    # set away, noaway
    $K->call($H->{alias}, 'away', 'testing away msg');
    $K->delay('sendaway',2);

}
sub record_test {
    my ($H,$test,$result) = @_[HEAP,ARG0,ARG1];
    $H->{tests}->{$test} = $result ? 'passed' : 'failed';
}
#
# show us some states!
#

sub error {
    my ($K,$H,$state,$msg) = @_[KERNEL, HEAP, STATE, ARG0];
    if ( !$H->{tests}->{'error_state'} ) {
	$H->{tests}->{'error_state'} = is($state, 'icb_client_error', 'state is icb_client_error');
    }
    if ( !$H->{tests}->{'error_msg'} ) {
	$H->{tests}->{'error_msg'} = ok($msg, "got error: '$msg'");
    }
}

sub default {
    my ($state,@args) = @_[STATE,ARG0..$#_];
    {
	local $Data::Dumper::Maxdepth = 2;
	print STDERR "Got state: $state  with args: \n";
	print STDERR Dumper(\@args);
	print STDERR "\n\n";
    }
}

sub h_protocol {
    my ($k,$H,$state,@args) = @_[KERNEL,HEAP,STATE,ARG0..ARG2];
    if ( !$H->{tests}->{'protocol'} ) {
	$H->{tests}->{protocol} = is(@args,3,sprintf("proto: %s, host id: %s, server id: %s", @args));
    }
}

sub h_client_connected {
    my ($K,$H) = @_[KERNEL,HEAP];
    if ( !$H->{tests}->{'client_connected'} ) {
	$H->{tests}->{client_connected} = ok(1,'client_connected');
    }

    $K->post($H->{alias}, 'login');
}

sub h_login_ok {
    my ($k,$H,$state) = @_[KERNEL,HEAP,STATE];
    ok($state, "login ok! -> $state");
    $H->{logged_in} = 1;
    if ( !$H->{tests}->{'login_ok'} ) {
	$H->{tests}->{login_ok} = ok(1,'login_ok');
    }
    $k->yield('run_tests');
}

sub h_cmdout {
    my ($k,$H,$state,$type,$content) = @_[KERNEL,HEAP,STATE,ARG0,ARG1];

    if ( $type == 'co' ) {
	if ( $content ) {
	    $H->{tests}->{co_type_and_content} = ok($type && $content, "cmd_out/co: got type and content ($type/$content)") if $H->{tests}->{co_type_and_content};
	} else {
	    $H->{tests}->{co_type} = ok($type, "cmd_out/co: got type ($type)") if $H->{tests}->{co_type};
	}
    }
    elsif ($type && $content) {
	ok($type && $content, "cmd_out: got type and content ($type/$content)");
    } elsif ($type) {
	ok($type, "cmd_out: got type ($type)");
    } else {
	ok(0, "cmd_out: no type!: '".join('|',$_[ARG0..$#_])."'");
    }
}

sub h_status {
    my ($k,$H,$state,$cat,$content) = @_[KERNEL,HEAP,STATE,ARG0,ARG1];

    $H->{tests}->{status_ok} = ok($state, "status ok! -> $state") unless $H->{tests}->{status_ok};
    $H->{tests}->{status_cat_and_content} = ok($cat && $content, "status: got category and content ($cat/$content)") unless $H->{tests}->{status_cat_and_content};
}
