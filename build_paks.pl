#!/usr/bin/perl 

use strict;
use warnings;

use Archive::Zip qw//;
use File::Path qw/mkpath/;
use File::Copy qw/mv/;
use File::Find qw/find/;
use File::Slurp qw/read_file/;
use YAML::Tiny qw/Dump Load/;
use File::Basename qw/dirname/;

my %zip_urls = qw(
    quake_authmdl.zip       https://github.com/NightFright2k19/quake_authmdl/archive/master.zip
    LibreQuake.zip          https://github.com/MissLav/LibreQuake/archive/master.zip
    quake_map_source.zip    https://github.com/fzwoch/quake_map_source/archive/master.zip
    OpenQuartz.zip          https://iweb.dl.sourceforge.net/project/openquartz/Open%20Quartz%20playable%20games/Open%20Quartz%202004.08.01/OpenQuartzWindows2004.08.01.zip
    Quake_Sound_Bulb.zip    https://sjc4.dl.dbolical.com/dl/2019/10/03/Quake_Sound_Bulb.zip
);

main(@ARGV);

sub main {
    my @yamlfiles = @_ ? @_ : qw/pak0.yml pak1.yml/;

    my $files = {};
    for my $yamlfile (@yamlfiles) {
        my $yaml = YAML::Tiny->read($yamlfile)->[0];
        %$files = (%$yaml, %$files);
    }

    my %zips = ();

    for my $zip (keys %zip_urls) {
        unless (-f $zip) {
            my $url = $zip_urls{$zip};

            system qw/wget -q -c -O/, "$zip.part", $url;
            mv "$zip.part", $zip unless $?;
        }

        $zips{$zip} = Archive::Zip->new();
        $zips{$zip}->read($zip);
    }

    my @paks = keys %$files;

    for my $pak (@paks) {
        for my $path (qw/gfx maps progs sound/) {
            mkpath "$pak/$path";
        }
    }

    for my $pak (keys %$files) {
        for my $path (keys %{$files->{$pak}}) {
            for my $name (keys %{$files->{$pak}->{$path}}) {
                for my $zip (keys %{$files->{$pak}->{$path}->{$name}}) {
                    my $file = $files->{$pak}->{$path}->{$name}->{$zip};

                    if (ref $file) {
                        my ($pakfile, $filename) = @$file;

                        if ($pakfile =~ /\.pak/) {
                            my $pakdata = $zips{$zip}->contents($pakfile);

                            extract_from_pak($pakdata, $filename, "$pak/$path/$name");
                        } elsif ($pakfile =~ /\.pk3/) {
                            unless ($zips{$pakfile}) {
                                my $pk3 = $zips{$zip}->contents($pakfile);

                                open my $fh, "+<", \$pk3;

                                $zips{$pakfile} = Archive::Zip->new();
                                $zips{$pakfile}->readFromFileHandle($fh);
                            }

                            if ($filename =~ /\/$/) {
                                mkpath "$pak/$path/$name";
                                $zips{$pakfile}->extractTree($filename, "$pak/$path/$name");
                            } else {
                                $zips{$pakfile}->extractMember($filename, "$pak/$path/$name");
                            }
                        }
                    } else {
                        $zips{$zip}->extractMember($file, "$pak/$path/$name");
                    }
                }
            }
        }
    }

    for my $pak (@paks) {
        create_pak("$pak.pak", $pak);
    }
}

sub extract_from_pak {
    my ($pak, $filename, $output) = @_;

    my ($id, $offset, $size) = unpack 'A4l<l<', $pak; 

    die "Invalid PAK file" if $id ne 'PACK';

    my $num_entries = $size/64;

    my @entries = unpack "\@$offset(Z56l<l<)$num_entries", $pak;

    my $pakfiles = {};

    while (@entries) {
        my $filename = shift @entries;
        my $filepos = shift @entries;
        my $filesize = shift @entries;

        $pakfiles->{$filename} = [$filepos, $filesize];
    }

    my @to_extract = ();

    if ($filename =~ /\/$/) {
        my $len = length $filename;

        for my $file (sort keys %$pakfiles) {
            if (substr($file, 0, $len) eq $filename) {
                push @to_extract, [$file, $output . substr($file, $len)];
            }
        }
    } else {
        die "File not found: `$filename'\n" unless $pakfiles->{$filename};
        @to_extract = ([$filename, $output]);
    }

    for my $extract (@to_extract) {
        my ($ex, $out) = @$extract;

        mkpath dirname $out;

        open my $fh, '>', $out or die "Could not write to `$out': $!\n";
        binmode $fh;
        print $fh substr($pak, $pakfiles->{$ex}->[0], $pakfiles->{$ex}->[1]);
        close $fh;
    }
}

sub create_pak {
    my ($output, $path) = @_;

    open my $fh, '>', $output or die "Could not write `$output': $!\n";

    # dummy header
    print $fh pack 'A4l<l<', 'PACK', 0, 0;

    my $offset = 12;

    my @entries = ();

    find({
        no_chdir => 1,
        wanted => sub {
            my $file = $File::Find::name;

            if (-f $file) {
                my $pakfile = substr($File::Find::name, length($path)+1);

                my $data = read_file $file;
                my $len = length $data;
                print $fh $data;
                push @entries, [$pakfile, $offset, $len];
                $offset += $len;
            } 
        }},
        $path
    );

    my $tablesize = 0;
    for my $entry (@entries) {
        print $fh pack 'Z56l<l<', @$entry;
        $tablesize += 64;
    }

    seek $fh, 4, 0;
    print $fh pack 'l<l<', $offset, $tablesize;

    close $fh;
}
