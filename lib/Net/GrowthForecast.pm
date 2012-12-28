package Net::GrowthForecast;

use strict;
use warnings;
use Carp;

use List::MoreUtils qw//;

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
        $obj = decode_json($res->content);
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
    my ($self, $service, $section, $name, $value, %options) = @_;
    my $url = $self->url("/api/$service/$section/$name");

    # url, headers, form-data
    my $res = $self->{furl}->post( $url, [], [ number => $value, %options ] );
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

sub edit {
    my ($self, $spec) = @_;
    unless (defined $spec->{id}) {
        croak "cannot edit graph without id (get graph data from GrowthForecast at first)";
    }
    my $url;
    if (defined $spec->{complex} and $spec->{complex}) {
        $url = $self->url("/json/edit/complex/" . $spec->{id});
    } else {
        $url = $self->url("/json/edit/graph/" . $spec->{id});
    }
    my $res = $self->{furl}->post($url, [], encode_json($spec));
    $self->check_response($res);
}

my @ADDITIONAL_PARAMS = qw(mode description sort gmode ulimit llimit sulimit sllimit type stype adjust adjustval unit);
sub add {
    my ($self, $spec) = @_;
    if (defined $spec->{complex} and $spec->{complex}) {
        return $self->_add_complex($spec);
    }
    if (List::MoreUtils::any { defined $spec->{$_} } @ADDITIONAL_PARAMS) {
        carp "cannot specify additional parameters for basic graph creation (except for 'color')";
    }
    $self->add_graph($spec->{service_name}, $spec->{section_name}, $spec->{graph_name}, $spec->{number}, $spec->{color});
}

sub add_graph {
    my ($self, $service, $section, $graph_name, $initial_value, $color) = @_;
    unless (List::MoreUtils::all { defined($_) and length($_) > 0 } $service, $section, $graph_name) {
        croak "service, section, graph_name must be specified";
    }
    $initial_value = 0 unless defined $initial_value;
    my %options = ();
    if (defined $color) {
        croak "color must be specified like #FFFFFF" unless $color =~ m!^#[0-9a-fA-F]{6}!;
        $options{color} = $color;
    }
    $self->post($service, $section, $graph_name, $initial_value, %options);
}

sub add_complex {
    my ($self, $service, $section, $graph_name, $description, $sumup, $sort, $type, $gmode, $stack, @data_graph_ids) = @_;
    unless ( List::MoreUtils::all { defined($_) } ($service,$section,$graph_name,$description,$sumup,$sort,$type,$gmode,$stack)
          and scalar(@data_graph_ids) > 0 ) {
        croak "all arguments must be specified, but missing";
    }
    croak "sort must be 0..19" unless $sort >= 0 and $sort <= 19;
    croak "type must be one of AREA/LINE1/LINE2, but '$type'" unless $type eq 'AREA' or $type eq 'LINE1' or $type eq 'LINE2';
    croak "gmode must be one of gauge/subtract" unless $gmode eq 'gauge' or $gmode eq 'subtract';
    my $spec = +{
        complex => JSON::XS::true,
        service_name => $service,
        section_name => $section,
        graph_name => $graph_name,
        description => $description,
        sumup => ($sumup ? JSON::XS::true : JSON::XS::false),
        sort => int($sort),
        data => [ map { +{ graph_id => $_, type => $type, gmode => $gmode, stack => $stack } } @data_graph_ids ],
    };
    $self->_add_complex($spec);
}

sub _add_complex {
    my ($self, $spec) = @_;
    my $url = $self->url("/json/create/complex");
    # url, headers, content
    my $res = $self->{furl}->post( $url, [], encode_json($spec) );
    $self->check_response($res);
}

1;
