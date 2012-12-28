use inc::Module::Install;

name 'Net-GrowthForecast';
all_from 'lib/Net/GrowthForecast.pm';
# readme_from 'lib/Net/GrowthForecast.pm';

requires 'JSON::XS';
requires 'Furl';

requires 'Try::Tiny';
requires 'Log::Minimal';
requires 'List::MoreUtils';

build_requires 'Test::More';

tests 't/*.t t/*/*.t';
# author_tests 'xt';

auto_set_repository;

WriteAll;
