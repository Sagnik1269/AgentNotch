#!/usr/bin/perl
# Loads AgentNotch's NowPlayingBridge.dylib into Apple's system perl and runs it.
# MediaRemote only serves now-playing data to Apple-signed processes on macOS 15.4+,
# and /usr/bin/perl is one. The dylib does the real work; this script just hosts it.
use strict;
use warnings;
use DynaLoader;

my $path = shift @ARGV or die "usage: nowplaying.pl <NowPlayingBridge.dylib>\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die "load failed: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "an_bridge_run") or die "an_bridge_run not found\n";
DynaLoader::dl_install_xsub("AgentNotch::run", $sym);
AgentNotch::run();
