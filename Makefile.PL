use inc::Module::Install;

name 'Net::GrowthForecast';
all_from 'lib/Net/GrowthForecast.pm';
readme_from 'lib/Net/GrowthForecast.pm';

requires 'JSON::XS';
requires 'Web::Query';
requires 'LWP::UserAgent';

requires 'Try::Tiny';
requires 'Log::Minimal';

build_requires 'Test::More';

tests 't/*.t t/*/*.t';
author_tests 'xt';

# install_script 'bin/gfclient';

auto_set_repository;

WriteAll;
