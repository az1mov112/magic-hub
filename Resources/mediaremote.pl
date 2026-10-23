#!/usr/bin/perl
# Мост к «Сейчас играет» для Magic Hub.
# Запуск: /usr/bin/perl mediaremote.pl <путь к libMediaRemoteBridge.dylib> stream|send
# Системный perl (com.apple.perl5) имеет доступ к MediaRemote, которого с macOS 15.4
# лишены сторонние приложения. Сама логика — в libMediaRemoteBridge.dylib.
use strict;
use warnings;
use DynaLoader;

my ($lib, $mode) = @ARGV;
die "usage: mediaremote.pl <dylib> stream|send\n" unless defined $lib && defined $mode;

my $func = $mode eq 'send' ? 'mh_send' : 'mh_stream';
my $handle = DynaLoader::dl_load_file($lib, 0)
    or die "dl_load_file failed: " . (DynaLoader::dl_error() // 'unknown') . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $func)
    or die "symbol $func not found\n";
DynaLoader::dl_install_xsub('main::mh_entry', $symbol);

$| = 1;
mh_entry();
exit 0;
