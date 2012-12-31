use inc::Module::Install;

name 'Net-GrowthForecast';
all_from 'lib/Net/GrowthForecast.pm';
# readme_from 'lib/Net/GrowthForecast.pm';

requires 'JSON::XS';
requires 'Furl';

requires 'Try::Tiny';
requires 'Log::Minimal';
requires 'List::MoreUtils';

requires 'Test::More';
requires 'File::Find::Rule';
build_requires 'Test::More';
build_requires 'File::Find::Rule';

tests 't/*.t';
# author_tests 'xt';

auto_set_repository;

WriteAll;
