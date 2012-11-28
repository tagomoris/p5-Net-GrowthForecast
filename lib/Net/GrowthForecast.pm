package Net::GrowthForecast;

use strict;
use warnings;
use Carp;

use JSON::XS;
use Web::Query;
use LWP::UserAgent;

use Try::Tiny;

our $VERSION = '0.01';

sub new {
    my ($this, %opts) = @_;
    my $agent = LWP::UserAgent->new( agent => 'Net::GrowthForecast' );
    my $self = +{
        proto => $opts{proto} || 'http',
        host => $opts{host} || 'localhost',
        port => $opts{port} || 5125,
        agent => $agent,
    };
    $Web::Query::UserAgent = $agent;

    bless $self, $this;
    $self->debug() if $opts{debug};
    $self;
}

sub debug {
    my $self = shift;
    $self->{_lwp_ua_request} = \&LWP::UserAgent::request;
    *LWP::UserAgent::request = sub {
        my $r = $self->{_lwp_ua_request}->(@_);
        use Data::Dumper;
        warn Dumper {res => $r};
        $r;
    };
}

sub check_response {
    my ($self, $res) = @_;
    return undef if $res->code != 200;
    return 1 unless $res->content;
    my $error;
    try {
        my $obj = decode_json($res->content);
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
    return (not $error);
}

sub url {
    my ($self, $path) = @_;
    my $base = $self->{proto} . '://' . $self->{host} . ($self->{port} == 80 ? '' : ':' . $self->{port});
    if ($path) {
        return $base . $path;
    }
    $base . '/';
}

sub post { # options are 'mode' and 'color' available
    my ($self, $service, $section, $name, $num, $value, %options) = @_;
    my $post_url = $self->url("/api/$service/$section/$name");

    my $res = $self->{agent}->post($post_url, +{ number => $value, %options });
    $self->check_response($res);
}

# arrayref of {service => 'service'}
sub services {
    my $self = shift;
    wq($self->url())
        ->find('h2 span')
        ->filter(sub{ $_->attr('class') ne 'pull-right'; })
        ->map(sub{ return +{ section => $_->find('a')->first->text }; });
}

# arrayref of {service => $service, section => $section}
sub sections {
    my ($self, $service) = @_;
    unless ($service) {
        croak "invalid arguments: service must be specified";
    }
    my $d = wq($self->url("/list/$service"));
    return [] unless $d;

    $d->find('.container section .row div table tr td a')
      ->map(sub{ return +{ service => $service, section => $_->text }; });
}

# arrayref of { service => $service, section => $section, name => $name, complex => $bool, id => $id }
sub graphs {
    my ($self, $service, $section) = @_;
    unless ($service and $section) {
        croak "invalid arguments: service and section must be specified";
    }
    my $d = wq($self->url("/list/$service/$section"));
    return [] unless $d;

    $d->find('.container section .row div h2 a')
      ->map(sub{
          my $id = $_->attr('data-id');
          my $complex = $_->attr('href') =~ m!/view_graph/!;
          my $name = $_->text;
          return +{ service => $service, section => $section, name => $name, complex => $complex, id => $id };
      });
}

# { service => $service, section => $section, name => $name, compled => $bool, id => $id }
sub graph {
    my ($self, $service, $section, $name) = @_;
    unless ($service and $section and $name) {
        croak "invalid arguments: service, section and name must be specified";
    }
    my @list = grep { $_->{name} eq $name } @{$self->graphs($service, $section)};
    return undef if scalar(@list) != 1; # specified graph not found

    $list[0];
}

sub info {
    my ($self, $graph) = @_;
    my $info;

    unless ($graph->{service} and $graph->{section} and $graph->{name}) {
        croak "invalid arguments: service, section and name must be specified";
    }
    unless ($graph->{id}) {
        my $g = $self->graph($graph->{service}, $graph->{section}, $graph->{name});
        return undef unless $g;
        $graph->{id} = $g->{id};
    }

    # if 'complex' is not specified, assume 'basic graph' at first, and try to get
    unless ($graph->{complex}) {
        $info = $self->info_basic_graph($graph);
    }
    # 'complex' is specified, or without type and cannot get basic graph
    # try complex graph
    unless ($info) {
        $info = $self->info_complex_graph($graph);
    }
    return undef unless $info;

    $info->{id} = $graph->{id};
    $info;
}

sub edit {
    my ($self, $graph) = @_;
    if ($graph->{complex}) {
        $self->edit_complex_graph($graph);
    } else {
        $self->edit_basic_graph($graph);
    }
}

sub add {
    my ($self, $graph) = @_;
    if ( $graph->{complex}
             or
         (defined($graph->{series}) and scalar(@{$graph->{series}}) > 0) ) {
        $self->add_complex($graph);
    } else {
        $self->add_graph($graph);
    }
}

sub info_basic_graph {
    my ($self, $graph) = @_;

    my $v = wq($self->url("/view_graph/$graph->{service}/$graph->{section}/$graph->{name}"));
    return undef unless $v;

    my $id = $v->find('.container section .row div h2 a')
        ->first
        ->attr('data-id');

    my $d = wq($self->url("/edit/$graph->{service}/$graph->{section}/$graph->{name}"));
    return undef unless $d;

    return +{
        id => $id,
        service => $d->find('input[name=service_name]')->attr('value'),
        section => $d->find('input[name=section_name]')->attr('value'),
        name => $d->find('input[name=graph_name]')->attr('value'),
        description => $d->find('input[name=description]')->attr('value'),
        # 0 ... 19
        sort => $d->find('select[name=sort] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
        # gauge subtract both
        gmode => $d->find('select[name=gmode] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
        # adjust => [adjust, adjustval, unit]
        #    adjust: '*' or '/'
        adjust => [
            $d->find('select[name=adjust] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
            $d->find('input[name=adjustval]')->attr('value'),
            $d->find('input[name=unit]')->attr('value')
        ],
        color => $d->find('input[name=color]')->attr('value'),
        # AREA, LINE1, LINE2
        type => $d->find('select[name=type] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
        llimit => $d->find('input[name=llimit]')->attr('value'),
        ulimit => $d->find('input[name=ulimit]')->attr('value'),
        # AREA, LINE1, LINE2
        stype => $d->find('select[name=stype] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
        # [sllimit, sulimit]
        sllimit => $d->find('input[name=sllimit]')->attr('value'),
        sulimit => $d->find('input[name=sulimit]')->attr('value'),
    };
}

sub edit_basic_graph {
    my ($self,$graph) = @_;
    my $post_url = $self->url("/edit/$graph->{service}/$graph->{section}/$graph->{name}");
    my $res = $self->{agent}->post(
        $post_url, +{
            service_name => $graph->{service}, section_name => $graph->{section}, graph_name => $graph->{name},
            description => $graph->{description}, sort => $graph->{sort}, gmode => $graph->{gmode},
            adjust => $graph->{adjust}->[0], adjustval => $graph->{adjust}->[1], unit => $graph->{adjust}->[2],
            color => $graph->{color}, type => $graph->{type}, stype => $graph->{stype},
            llimit => $graph->{llimit}, ulimit => $graph->{ulimit}, sllimit => $graph->{sllimit}, sulimit => $graph->{sulimit},
        }
    );
    $self->check_response($res);
}

sub add_graph {
    my ($self, $opts) = @_;
    my $check = sub { my $val = shift; defined($val) and length($val) > 0; };
    croak "service missing" unless $check->($opts->{service});
    croak "section missing" unless $check->($opts->{section});
    croak "graph name missing" unless $check->($opts->{name});

    if ($self->graph($opts->{service}, $opts->{section}, $opts->{name})) {
        croak "specified graph name already exists: $opts->{service}/$opts->{section}/$opts->{name}";
    }

    my $post_url = $self->url("/api/$opts->{service}/$opts->{section}/$opts->{name}");
    my $res = $self->{agent}->post($post_url, +{
        number => 0,
        mode => 'count',
        (defined($opts->{color}) ? (color => $opts->{color}) : ())
    });
    $self->check_response($res);
}

sub info_complex_graph {
    my ($self, $graph) = @_;

    my $v = wq($self->url("/view_complex/$graph->{service}/$graph->{section}/$graph->{name}"));
    return undef unless $v;

    my $id = $v->find('.container section .row div h2 a')
        ->first
        ->attr('data-id');

    my $d = wq($self->url("/edit_complex/$graph->{id}"));
    return undef unless $d;

    my $series = [
        +{
            id => $d->find('select[name=path-1] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
            path => $d->find('select[name=path-1] option')->filter(sub{ $_->attr('selected'); })->text,
            # AREA LINE1 LINE2
            type => $d->find('select[name=type-1] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
            gmode => $d->find('select[name=gmode-1] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
            stack => undef,
        }
    ];
    my $series_table = $d->find('table')->filter(sub{ my $id = $_->attr('id'); defined $id and $id eq 'add-data-tbl'; })->first;
    $series_table
        ->find('tr.can-table-order')
        ->each(sub{
            my $graph = +{};
            $_->find('input')->each(sub{
                my $field = $_->attr('name');
                my $value = $_->attr('value');
                if ($field =~ /^type-/) {
                    $graph->{type} = $value;
                } elsif ($field =~ /^path/) {
                    $graph->{id} = $value;
                    $graph->{path} = $_->parent->text;
                } elsif ($field =~ /^gmode/) {
                    $graph->{gmode} = $value;
                } elsif ($field =~ /^stack/) {
                    $graph->{stack} = $value;
                }
            });
            push @$series, $graph;
        });

    return +{
        id => $id,
        service => $d->find('input[name=service_name]')->attr('value'),
        section => $d->find('input[name=section_name]')->attr('value'),
        name => $d->find('input[name=graph_name]')->attr('value'),
        description => $d->find('input[name=description]')->attr('value'),
        # 0 or 1
        sumup => $d->find('select[name=sumup] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
        # 0 ... 19
        sort => $d->find('select[name=sort] option')->filter(sub{ $_->attr('selected'); })->first->attr('value'),
        # [{id, path, gmode, stack}, ...]
        series => $series,
    };
}

sub edit_complex_graph {
    my ($self, $graph) = @_;
    my $post_url = $self->url("/edit_complex/$graph->{id}");
    my ($s1, @s2) = @{$graph->{series}};
    my %series = (
        'path-1' => $s1->{id}, 'type-1' => $s1->{type}, 'gmode-1' => $s1->{gmode},
        'path-2' => [],        'type-2' => [],          'gmode-2' => [],           'stack-2' => [],
    );
    foreach my $s2 (@s2) {
        push @{$series{'path-2'}}, $s2->{id};
        push @{$series{'type-2'}}, $s2->{type};
        push @{$series{'gmode-2'}}, $s2->{gmode};
        push @{$series{'stack-2'}}, $s2->{stack};
    }
    my $res = $self->{agent}->post( $post_url, +{
        service_name => $graph->{service}, section_name => $graph->{section}, graph_name => $graph->{name},
        description => $graph->{description}, sort => $graph->{sort}, gmode => $graph->{gmode},
        sumup => $graph->{sumup}, sort => $graph->{sort},
        %series,
    });
    $self->check_response($res);
}

sub add_complex {
    my ($self, $opts) = @_;
    my $check = sub { my $val = shift; defined($val) and length($val) > 0; };
    croak "service missing" unless $check->($opts->{service});
    croak "section missing" unless $check->($opts->{section});
    croak "graph name missing" unless $check->($opts->{name});

    croak "complex graph series missing" unless defined $opts->{series} and scalar(@{$opts->{series}}) > 0;

    my $series = delete $opts->{series};
    my ($first, @rest) = @$series;
    croak "No one sub graph exists for complex graph" unless $first and $first->{id};

    if ($self->graph($opts->{service}, $opts->{section}, $opts->{name})) {
        croak "specified graph name already exists: $opts->{service}/$opts->{section}/$opts->{name}";
    }

    my $args = +{
        service_name => $opts->{service},
        section_name => $opts->{section},
        graph_name => $opts->{name},
        description => $opts->{description} || '',
        sumup => $opts->{sumup} || 0,
        sort => $opts->{sort} || 19,
    };

    $args->{'path-1'} = $first->{id};
    $args->{'type-1'} = $first->{type} || 'AREA';
    $args->{'gmode-1'} = (defined($first->{gmode}) and $first->{gmode} eq 'subtract') ? 'subtract' : 'gauge';

    if (scalar(@rest) > 0) {
        $args->{'path-2'} = [];
        $args->{'type-2'} = [];
        $args->{'gmode-2'} = [];
        $args->{'stack-2'} = [];
        foreach my $r (@rest) {
            push @{$args->{'path-2'}}, $r->{id};
            push @{$args->{'type-2'}}, $r->{type} || 'AREA';
            push @{$args->{'gmode-2'}}, (defined($r->{gmode}) and $r->{gmode} eq 'subtract') ? 'subtract' : 'gauge';
            push @{$args->{'stack-2'}}, defined($r->{stack}) ? $r->{stack} : '1';
        }
    }

    my $post_url = $self->url('/add_complex');
    my $res = $self->{agent}->post($post_url, $args);
    $self->check_response($res);
}

1;
