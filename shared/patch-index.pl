#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;

my $index;
my @add;
my @remove;

GetOptions(
	"index=s"  => \$index,
	"add=s"    => \@add,
	"remove=s" => \@remove
);


unless (defined($index) && -f $index && (@add || @remove))
{
	die "Usage: $0 --index <pkg index> --add <pkg> --remove <pkg>\n";
}

sub pkg_basename
{
	my $file = shift || return;

	return undef unless -f $file;

	my ($name) = $file =~ m!^(?:.+/)?([^_/]+)[^/]+\.ipk$!;

	return $name;
}

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
	my ($name) = $file =~ m!([^/]+)$!;

	if (open TAR, "tar -xzOf $file ./control.tar.gz | tar -xzOf - ./control |")
	{
		while (defined(my $line = readline TAR))
		{
			if ($line =~ /^Description:/)
			{
				$meta .= sprintf "Filename: %s\n", $name;
				$meta .= sprintf "Size: %d\n", $size;
				$meta .= sprintf "MD5Sum: %s\n", $md5sum;
				$meta .= sprintf "SHA256sum: %s\n", $sha256sum;
			}

			$meta .= $line;
		}

		$meta .= "\n";

		close TAR;
	}

	# Fix up source
	$meta =~ s!^Source: .+/(feeds/.+)$!Source: $1!m;
	$meta =~ s!^Source: feeds/base/!Source: !m;

	return $meta;
}


my %addpkg;
my %rempkg;

foreach my $pkg (@add)
{
	my $name = pkg_basename($pkg);
	my $meta = pkg_metadata($pkg);

	if (!defined $name || !defined $meta)
	{
		warn "$pkg is not a valid .ipk file\n";
		next;
	}

	$addpkg{$name} = $meta;
	$rempkg{$name} = 1;
}

my ($cur_pkg, $cur_meta);
my $cat = ($index =~ /\.gz$/) ? "zcat" : "cat";

@rempkg{@remove} = (1) x @remove;

if (open IDX, "$cat $index |")
{
	while (1)
	{
		my $line = readline IDX;

		if (defined($line) && $line =~ /^Package: (.+)$/)
		{
			$cur_pkg = $1;
			$cur_meta = $line;
		}
		elsif (defined($line) && $line !~ /^$/ && defined($cur_meta))
		{
			$cur_meta .= $line;
		}
		else
		{
			foreach my $add (sort keys %addpkg)
			{
				if (!defined($cur_pkg) || $add le $cur_pkg)
				{
					print $addpkg{$add};
					delete $addpkg{$add};

					#$cur_pkg = $add;					
				}
			}
			
			if (defined($cur_pkg) && !$rempkg{$cur_pkg})
			{
				print $cur_meta, "\n";
			}

			undef $cur_pkg;
			undef $cur_meta;
		}

		last unless defined $line;
	}

	close IDX;
}
