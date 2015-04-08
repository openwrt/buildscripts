#!/usr/bin/perl

use strict;
use warnings;
use POSIX;

my $dir = $ARGV[0];

die "Usage: $0 <package directory>\n" unless -d $dir;

setlocale(LC_ALL, "C");

sub pkg_metadata
{
	my $file = shift || return;

	return undef unless -f $file;

	my $size = -s $file;
	my $md5sum;
	my $sha256sum;

	if (open MD5, "md5sum $file |")
	{
		if (defined(my $line = readline MD5))
		{
			($md5sum) = $line =~ /^([0-9a-fA-F]{32})/;
		}

		close MD5;
	}

	if (open SHA256, "openssl dgst -sha256 $file |")
	{
		if (defined(my $line = readline SHA256))
		{
			($sha256sum) = $line =~ /([0-9a-fA-f]{64})$/;
		}

		close SHA256;
	}

	return undef unless $md5sum && $sha256sum;

	my $meta = '';

	if (open TAR, "tar -xzOf $file ./control.tar.gz | tar -xzOf - ./control |")
	{
		while (defined(my $line = readline TAR))
		{
			if ($line =~ /^Description:/)
			{
				$meta .= sprintf "Size: %d\n", $size;
				$meta .= sprintf "MD5Sum: %s\n", $md5sum;
				$meta .= sprintf "SHA256sum: %s\n", $sha256sum;
			}

			$meta .= $line;
		}

		$meta .= "\n";

		close TAR;
	}

	return $meta;
}


my @packages;

if (opendir D, $dir)
{
	while (defined(my $e = readdir D))
	{
		next unless -f "$dir/$e" && $e =~ m{\.ipk$};
		push @packages, $e;
	}

	closedir D;
}

foreach my $package (sort @packages)
{
	print pkg_metadata("$dir/$package");
}
