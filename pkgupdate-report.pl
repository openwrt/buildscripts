#!/usr/bin/env perl

use strict;
use warnings;

use lib "shared";
use config;

use Cwd;
use Encode;
use MIME::Lite;
use File::Basename;

use Getopt::Long;

my $text_width = 72;

my $do_check   = 0;
my $do_preview = 0;
my $do_send    = 0;
my $do_pull    = 0;

my $changetime;
my @use_packages;
my @use_cve;
my @use_ref;

GetOptions(
	'check'     => \$do_check,
	'preview'   => \$do_preview,
	'send'      => \$do_send,
	'pull'      => \$do_pull,
	'since=s'   => \$changetime,
	'package=s' => \@use_packages,
	'cve=s'     => \@use_cve,
	'ref=s'     => \@use_ref,
);

unless ($do_check || $do_preview || $do_send)
{
	die <<EOT;

Check for updates:

	$0 [--pull] [--since ...] [--package ...] --check

Generate mail report:

	$0 [--cve ...] [--ref ...] [--since ...] [--package ...] {--preview|--send}

Actions:

	--check    Test for package changes since last sync or the time specified
	           by `--since`

	--preview  Display the mail report that would be sent

	--send     Send mail report

Options:

	--pull     Perform a `git pull` in the feed clones before checking changes

	--since <TIME>
	           Specify the start time when checking changes

	--package <NAME>
	           Only consider given source package, multiple allowed

	--cve <CVE>
	           Include given CVE number in report

	--ref <URL>
	           Include given url in report
	
EOT
}

sub last_change_time {
	my $changetime = 0;

	if (open my $find, 'find .cache/repo-remote -type f -name Packages.gz -printf "%C@\n" |')
	{
		while (defined(my $timestamp = readline $find))
		{
			$timestamp = int $timestamp;
			$changetime = $timestamp if ($timestamp > $changetime);
		}

		close $find;
	}

	return $changetime;
}

sub wrap_paragraph {
	my $pad1 = shift;
	my $pad2 = shift;
	my @words = map { split /\s+/ } @_;
	my $line = '';
	my @out;

	foreach my $word (@words)
	{
		my $line_len = length($line);

		if (($line_len + length($word) + 1) > $text_width)
		{
			push @out, $pad1 . (@out > 0 ? $pad2 : '') . $line;
			$line = $word;
		}
		else
		{
			$line .= ($line_len ? ' ' : '') . $word;
		}
	}

	push @out, $pad1 . (@out > 0 ? $pad2 : '') . $line;
	return @out;
}

sub format_paragraph {
	my $para = shift || return '';

	my @lines = split /\n/, $para;
	my @part;
	my @out;

	foreach my $line (@lines)
	{
		if ($line =~ /^\s*([*-]|\d+\))\s+/)
		{
			my $pad = ' ' x (length($1) + 1);

			if (@part > 0)
			{
				push @out, wrap_paragraph('', '', @part);
				@part = ();
			}

			push @out, wrap_paragraph(' ', $pad, $line);
		}
		else
		{
			push @part, $line;
		}
	}

	if (@part > 0)
	{
		push @out, wrap_paragraph('', '', @part);
	}

	return join "\n", @out;
}

sub get_pkg_name {
	my $pkg = shift || return undef;

	if ($pkg->{is_package} && defined($pkg->{PKG_NAME}))
	{
		return $pkg->{PKG_NAME};
	}

	return undef;
}

sub get_pkg_version {
	my $pkg = shift || return undef;

	if (defined($pkg->{PKG_VERSION}) && defined($pkg->{PKG_RELEASE}))
	{
		return sprintf '%s-%s', $pkg->{PKG_VERSION}, $pkg->{PKG_RELEASE};
	}
	elsif (defined($pkg->{PKG_VERSION}))
	{
		return $pkg->{PKG_VERSION};
	}
	elsif (defined($pkg->{PKG_RELEASE}))
	{
		return $pkg->{PKG_RELEASE};
	}

	return undef;
}

sub parse_pkg_info {
	my ($hash, $pkgdir) = @_;
	my $pkg = { };

	if (open my $fd, "git show $hash:$pkgdir/Makefile |")
	{
		while (defined(my $line = readline $fd))
		{
			if ($line =~ /^\s*(\w+)\s*(?:\?=|:=|=)\s*(\S.*)$/)
			{
				$pkg->{$1} = $2;
			}
			elsif ($line =~ /call +BuildPackage/)
			{
				$pkg->{is_package} = 1;
			}
		}

		close $fd;
	}

	foreach my $key (keys %$pkg)
	{
		$pkg->{$key} =~ s!\$\((\w+)\)!exists($pkg->{$1}) ? $pkg->{$1} : ''!eg;
	}

	return $pkg;
}

sub generate_pkg_log {
	my ($feedname, $changetime, $pkgdir) = @_;

	my ($prev_pkg, $curr_pkg, $prev_hash, $curr_hash);
	my (@log, %cve);
	my ($subj, $date, @body, @refs);

	if (open my $fd, "git log --since='$changetime' --format='%H' -- '$pkgdir' |")
	{
		my @hashes;

		while (defined(my $hash = readline $fd))
		{
			chomp $hash;
			push @hashes, $hash;
		}

		if (exists $conf{commitlink}{$feedname})
		{
			foreach my $hash (reverse @hashes)
			{
				push @refs, sprintf $conf{commitlink}{$feedname}, $hash;
			}
		}

		close $fd;

		$prev_hash = pop @hashes;
		$curr_hash = shift @hashes || $prev_hash;

		if (defined($prev_hash) && open my $fd, "git log --format='%H' $prev_hash~1 -- '$pkgdir' |")
		{
			if (defined(my $hash = readline $fd))
			{
				chomp $hash;
				$prev_hash = $hash;
			}

			close $fd;
		}

		$prev_pkg = parse_pkg_info($prev_hash, $pkgdir);
		$curr_pkg = parse_pkg_info($curr_hash, $pkgdir);
	}

	if (!defined($curr_pkg) || !defined($prev_pkg) ||
	    !$curr_pkg->{is_package} || !$prev_pkg->{is_package})
	{
		return;
	}

	if (open my $fd, "git log --since='$changetime' --format='\@S:%s%n\@D:%cD %h%n\@B:%b%n\@\@' -- '$pkgdir' |")
	{
		@cve{@use_cve} = (1) x @use_cve;

		while (defined(my $line = readline $fd))
		{
			chomp $line;

			foreach my $cve ($line =~ m!\bCVE-\d{4}-\d{4,}\b!g)
			{
				$cve{$cve}++;
			}

			if ($line =~ m!^\@S:(.+)$!)
			{
				$subj = $1;
				$subj =~ s/^\S+: //;
				$subj =~ s/^\[[^\[\]]+\][: ]+//;
			}
			elsif ($line =~ m!\@D:(.+)$! && defined($subj))
			{
				$date = $1;
			}
			elsif ($line =~ m!\@B:(.*)$! && defined($date) && !@body)
			{
				@body = ($1);
			}
			elsif ($line =~ m!\@\@! && @body > 0)
			{
				@body = grep {
					$_ !~ m!^Signed-off-by: !    &&
			        $_ !~ m!^Acked-by: !         &&
					$_ !~ m!^ ?Backport of r\d+! &&
			        $_ !~ m!^git-svn-id: !;
				} @body;

				my $body = join "\n", @body;
				   $body =~ s/\s+$//;

				$body = ucfirst($subj) . "\n\n" . $body
					unless $body =~ /\n/;

				$body = join "\n\n",
						map { format_paragraph($_) }
						split /\n\n/, $body;

				push @log, sprintf("[%s]\n\n%s", $date, $body);

				undef $subj;
				undef $date;
				undef @body;
			}
			elsif (@body > 0)
			{
				push @body, $line;
			}
		}

		close $fd;
	}

	my @cve = sort keys %cve;
	my ($sub, $out);

	if (@cve > 0)
	{
		if (@cve > 1)
		{
			$sub = sprintf("%s: Security update (%d CVEs)\n\n",
						   $curr_pkg->{PKG_NAME}, @cve + 0);

			$out = join "\n", wrap_paragraph('', '', sprintf(
				"The %s package has been rebuilt and was uploaded to the %s repository due to multiple security issues.\n",
				$curr_pkg->{PKG_NAME}, $conf{release_name}
			));
		}
		else
		{
			$sub = sprintf("%s: Security update (%s)\n\n",
						   $curr_pkg->{PKG_NAME}, $cve[0]);

			$out = join "\n", wrap_paragraph('', '', sprintf(
				"The %s package has been rebuilt and was uploaded to the %s repository due to a reported security issue.\n",
				$curr_pkg->{PKG_NAME}, $conf{release_name}
			));
		}
	}
	else
	{
		$sub = sprintf("%s: Update\n\n",
					   $curr_pkg->{PKG_NAME});

		$out = join "\n", wrap_paragraph('', '', sprintf(
			"The %s package has been rebuilt and was uploaded to the %s repository.\n",
			$curr_pkg->{PKG_NAME}, $conf{release_name}
		));
	}

	$out .= "\n\n";

	my $prev_version = get_pkg_version($prev_pkg);
	my $curr_version = get_pkg_version($curr_pkg);

	if ($prev_version && $curr_version)
	{
		$out .= sprintf("\nVERSION\n\n%s\n\n", join "\n",
						wrap_paragraph('', '  ', "$prev_version => $curr_version"));
	}

	$out .= sprintf("\nCHANGELOG\n\n");

	foreach my $entry (@log)
	{
		$out .= sprintf("%s\n\n", $entry);
	}

	$out .= sprintf("\nCHANGES\n\n");

	if (open my $fd, "git diff --stat=$text_width $prev_hash..$curr_hash -- '$pkgdir' |")
	{
		while (defined(my $line = readline $fd))
		{
			chomp $line;
			$out .= sprintf("%s\n", $line);
		}

		close $fd;

		$out .= "\n";
	}

	if (@use_ref > 0 || @refs > 0 || @cve > 0)
	{
		$out .= sprintf("\nREFERENCES\n\n");

		foreach my $cve (@cve)
		{
			$out .= sprintf(" * http://cve.mitre.org/cgi-bin/cvename.cgi?name=%s\n", $cve);
		}

		foreach my $link (@use_ref, @refs)
		{
			$out .= sprintf(" * %s\n", $link);
		}
	}

	return ($sub, $out, @cve > 0);
}

sub generate_mail_subject
{
	my $s = sprintf("[%s] %s", $conf{release_tag}, $_[0]);

	utf8::decode($s);

	return encode('MIME-Q', $s);
}

my $workdir = Cwd::getcwd();
my @source_pkgs;

$changetime = last_change_time()
	unless defined $changetime;

if (open my $find, "find $workdir/.cache/feeds/ -type d -name .git -printf '%h\n' |")
{
	while (defined(my $feeddir = readline $find))
	{
		chomp $feeddir;
		chdir $feeddir || next;

		my $feedname = File::Basename::basename($feeddir);
		my %packages;

		if ($do_pull)
		{
			system('git pull --ff >/dev/null 2>/dev/null');
		}

		if (open my $gitlog, "git log --since='$changetime' --name-only --format='#%h' |")
		{
			while (defined(my $line = readline $gitlog))
			{
				next unless $line =~ m!^(.+)/Makefile$!;

				my $pkg_dir  = $1;
				my $pkg_name = File::Basename::basename($pkg_dir);

				if (!@use_packages || grep { $pkg_name eq $_ } @use_packages)
				{
					$packages{$pkg_dir}++;
				}
			}

			close $gitlog;
		}

		foreach my $package (sort keys %packages)
		{
			my ($subject, $body, $security) = generate_pkg_log($feedname, $changetime, $package);

			next unless $subject && $body;

			if ($do_send || $do_preview)
			{
				my $to = $security ? $conf{recipients_security} : $conf{recipients_standard};
				my $msg = MIME::Lite->new(
					From     => $conf{smtp}{from},
					To       => join(', ', @$to),
					Subject  => generate_mail_subject($subject),
					Data     => $body,
					Type     => 'text/plain; charset="UTF-8"'
				);

				if ($do_send)
				{
					$msg->send('smtp', $conf{smtp}{host},
						Timeout => 10,
						AuthUser => $conf{smtp}{user},
						AuthPass => $conf{smtp}{pass}
					);
				}
				else
				{
					print $msg->as_string, "\n===\n";
				}
			}
			else
			{
				warn "$subject\n";

				push @source_pkgs, File::Basename::basename($package);
			}
		}
	}

	close $find;
}

if ($do_check)
{
	if (!@source_pkgs)
	{
		printf("No updates.\n");
		exit(0);
	}

	printf("./pkgupdate-build.sh -ubi -s %s\n", join(' -s ', @source_pkgs));
	printf("./pkgupdate-report.pl --since %s%s --send\n",
		$changetime,
		@use_packages ? ' --package ' . join(' --package ', @use_packages) : '');
}
