package Net::GrowthForecast;

use strict;
use warnings;
use Carp;

use Furl;
use JSON::XS;

use Try::Tiny;

our $VERSION = '0.01';

#TODO: basic authentication support

sub new {
    my ($this, %opts) = @_;
    my $prefix = $opts{prefix} || '/';
    $prefix = '/' . $prefix unless $prefix =~ m!^/!;
    $prefix =~ s!/$!!;

    my $self = +{
        host => $opts{host} || 'localhost',
        port => $opts{port} || 5125,
        prefix => $prefix,
        timeout => $opts{timeout} || 30,
        useragent => 'Net::GrowthForecast',
    };
    $self->{furl} = Furl::HTTP->new(agent => $self->{useragent}, timeout => $self->{timeout}, max_redirects => 0);

    bless $self, $this;
    $self;
}

sub url {
    my ($self, $path) = @_;
    my $base = 'http://' . $self->{host} . ($self->{port} == 80 ? '' : ':' . $self->{port}) . $self->{prefix};
    $path ||= '/';
    $base . $path;
}

sub check_response {
    # check response body with "$c->render_json({ error => 1 , message => '...' })" style error status
    my ($self, $res) = @_;
    return undef if $res->code != 200;
    return 1 unless $res->content;
    my $error;
    my $obj;
    try {
        $obj = decode_json($body);
        if (defined($obj) and $obj->{error}) {
            carp "request ended with error:";
            foreach my $k (keys %{$obj->{messages}}) {
                carp "  $k: " . $obj->{messages}->{$k};
            }
            carp "  request(" . $res->request->method . "):" .  $res->request->uri;
            carp "  request body:" . $res->request->content;
            $error = 1;
        }
    } catch { # failed to parse json
        carp "failed to parse response content as json";
        carp "  content:" . $res->content;
        $error = 1;
    };
    return undef if $error;
    $obj;
}

sub post { # options are 'mode' and 'color' available
    my ($self, $service, $section, $name, $num, $value, %options) = @_;
    my $url = $self->url("/api/$service/$section/$name");

    # url, headers, form-data
    my $res = $furl->post( $url, [], [ number => $value, %options ] );
    $self->check_response($res);
}

sub get_internal {
    my ($self, $path) = @_;
    my $res = $self->url($path);
    $self->check_response($self->{furl}->get( $self->url($path), [] ));
}

sub graph {
    my ($self, $id) = @_;
    $self->get_internal("/json/graph/$id");
}

sub complex {
    my ($self, $id) = @_;
    $self->get_internal("/json/complex/$id");
}

sub graphs {
    my ($self) = @_;
    $self->get_internal("/json/list/graph") or [];
}

sub complexes {
    my ($self) = @_;
    $self->get_internal("/json/list/complex") or [];
}

sub all {
    my ($self) = @_;
    $self->get_internal("/json/list/all") or [];
}

sub tree {
    my ($self) = @_;
    my $services = {};
    my $all = $self->all();
    foreach my $node (@$all) {
        $services->{$node->{service_name}} ||= {};
        $services->{$node->{service_name}}->{$node->{section_name}} ||= {};
        $services->{$node->{service_name}}->{$node->{section_name}}->{$node->{graph_name}} = $node;
    }
    $services;
}

sub add {
    my ($self, $spec) = @_;
    ####
}

sub edit {
    my ($self, $spec) = @_;
    ####
}


1;
