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
    $self->{debug} = $opts{debug} || 0;

    bless $self, $this;
    $self;
}

sub _url {
    my ($self, $path) = @_;
    my $base = 'http://' . $self->{host} . ($self->{port} == 80 ? '' : ':' . $self->{port}) . $self->{prefix};
    $path ||= '/';
    $base . $path;
}

sub _request {
    my ($self, $method, $path, $headers, $content) = @_;
    my $url = $self->_url($path);
    my @res;
    my $list = undef;
    if ($method eq 'GET') {
        @res = $self->{furl}->get( $url, $headers || [], $content );
    } elsif ($method eq 'GET_LIST') {
        @res = $self->{furl}->get( $url, $headers || [], $content );
        $list = 1;
    } elsif ($method eq 'POST') {
        @res = $self->{furl}->post( $url, $headers || [], $content );
    } else {
        die "not implemented here.";
    }
    # returns a protocol minor version, status code, status message, response headers, response body
    my ($protocol_ver, $code, $message, $h, $c) = @res;
    $self->_check_response($url, $method, $code, $c, $list);
}

sub _check_response {
    # check response body with "$c->render_json({ error => 1 , message => '...' })" style error status
    my ($self, $url, $method, $code, $content, $list_flag) = @_;
    return [] if $list_flag and $code eq '404';
    if ($code ne '200') {
        # TODO fix GrowthForecast::Web not to return 500 when graph not found (or other case...)
        if ($self->{debug}) {
            carp "GrowthForecast returns response code $code";
            carp " request ($method) $url";
            carp " with content $content";
        }
        return undef;
    }
    return 1 unless $content;
    my $error;
    my $obj;
    try {
        $obj = decode_json($content);
        if (defined($obj) and ref($obj) eq 'ARRAY') {
            return $obj;
        } elsif (defined($obj) and $obj->{error}) {
            warn "request ended with error:";
            foreach my $k (keys %{$obj->{messages}}) {
                warn "  $k: " . $obj->{messages}->{$k};
            }
            warn "  request(" . $method . "):" .  $url;
            warn "  request body:" . $content;
            $error = 1;
        }
    } catch { # failed to parse json
        warn "failed to parse response content as json, with error: $_";
        warn "  content:" . $content;
        $error = 1;
    };
    return undef if $error;
    return $obj if ref($obj) eq 'ARRAY';
    if (defined $obj->{error}) {
        return $obj->{data} if $obj->{data};
        return 1;
    }
    $obj;
}

sub post { # options are 'mode' and 'color' available
    my ($self, $service, $section, $name, $value, %options) = @_;
    $self->_request('POST', "/api/$service/$section/$name", [], [ number => $value, %options ] );
}

sub by_name {
    my ($self, $service, $section, $name) = @_;
    my $tree = $self->tree();
    (($tree->{$service} || {})->{$section} || {})->{$name};
}

sub graph {
    my ($self, $id) = @_;
    if (ref($id) and ref($id) eq 'Hash' and defined $id->{id}) {
        $id = $id->{id};
    }
    $self->_request('GET', "/json/graph/$id");
}

sub complex {
    my ($self, $id) = @_;
    if (ref($id) and ref($id) eq 'Hash' and defined $id->{id}) {
        $id = $id->{id};
    }
    $self->_request('GET', "/json/complex/$id");
}

sub graphs {
    my ($self) = @_;
    $self->_request('GET_LIST', "/json/list/graph");
}

sub complexes {
    my ($self) = @_;
    $self->_request('GET_LIST', "/json/list/complex");
}

sub all {
    my ($self) = @_;
    $self->_request('GET_LIST', "/json/list/all");
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
    my $path;
    if (defined $spec->{complex} and $spec->{complex}) {
        $path = "/json/edit/complex/" . $spec->{id};
    } else {
        $path = "/json/edit/graph/" . $spec->{id};
    }
    $self->_request('POST', $path, [], encode_json($spec));
}

sub delete {
    my ($self, $spec) = @_;
    unless (defined $spec->{id}) {
        croak "cannot delete graph without id (get graph data from GrowthForecast at first)";
    }
    my $path;
    if (defined $spec->{complex} and $spec->{complex}) {
        $path = "/delete_complex/" . $spec->{id};
    } else {
        $path = join('/', "/delete", $spec->{service_name}, $spec->{section_name}, $spec->{graph_name});
    }
    $self->_request('POST', $path);
}

my @ADDITIONAL_PARAMS = qw(description sort gmode ulimit llimit sulimit sllimit type stype adjust adjustval unit);
sub add {
    my ($self, $spec) = @_;
    if (defined $spec->{complex} and $spec->{complex}) {
        return $self->_add_complex($spec);
    }
    if (List::MoreUtils::any { defined $spec->{$_} } @ADDITIONAL_PARAMS) {
        carp "cannot specify additional parameters for basic graph creation (except for 'mode' and 'color')";
    }
    $self->add_graph($spec->{service_name}, $spec->{section_name}, $spec->{graph_name}, $spec->{number}, $spec->{color}, $spec->{mode});
}

sub add_graph {
    my ($self, $service, $section, $graph_name, $initial_value, $color, $mode) = @_;
    unless (List::MoreUtils::all { defined($_) and length($_) > 0 } $service, $section, $graph_name) {
        croak "service, section, graph_name must be specified";
    }
    $initial_value = 0 unless defined $initial_value;
    my %options = ();
    if (defined $color) {
        croak "color must be specified like #FFFFFF" unless $color =~ m!^#[0-9a-fA-F]{6}!;
        $options{color} = $color;
    }
    if (defined $mode) {
        $options{mode} = $mode;
    }
    $self->post($service, $section, $graph_name, $initial_value, %options)
        and 1;
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

sub _add_complex { # used from add_complex() and also from add() directly (with spec format argument)
    my ($self, $spec) = @_;
    $self->_request('POST', "/json/create/complex", [], encode_json($spec) );
}

sub debug {
    my ($self, $mode) = @_;
    if (scalar(@_) == 2) {
        $self->{debug} = $mode ? 1 : 0;
        return;
    }
    # To use like this; $gf->debug->add(...)
    Net::GrowthForecast->new(%$self, debug => 1);
}

1;
