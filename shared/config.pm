package config;

use Exporter 'import';

@EXPORT = qw(%conf);

our %conf;

if (open CONF, "< shared/relman.cfg")
{
	while (defined(my $line = readline CONF))
	{
		chomp $line;

		if ($line =~ m!^\s*(\w+)(\{\w+\}|\[\d+\])?\s*=\s*(\S|\S.*\S)\s*$!)
		{
			my ($key, $idx, $val) = ($1, $2, $3);

			$val =~ s!\$(\w+|\{\w+\})!
				exists($conf{$1}) ? $conf{$1} :
					(exists($ENV{$1}) ? $ENV{$1} : '')
			!eg;

			if ($idx && $idx =~ m!^\{(\w+)\}$!)
			{
				$conf{$key} = { }
					unless exists($conf{$key}) && ref($conf{$key}) eq 'HASH';

				$conf{$key}{$1} = $val;
			}
			elsif ($idx && $idx =~ m!^\[(\d+)\]$!)
			{
				$conf{$key} = [ ]
					unless exists($conf{$key}) && ref($conf{$key}) eq 'ARRAY';

				$conf{$key}[int($1)] = $val;
			}
			else
			{
				$conf{$key} = $val;
			}
		}
	}

	close CONF;
}
else
{
	die "Unable to open configuration: $!\n";
}

sub sq($)
{
	my $s = $_[0];
	   $s =~ s/'/'"'"'/g;

	return $s;
}

unless (caller)
{
	foreach my $key (sort keys %conf)
	{
		if (ref($conf{$key}) eq 'HASH')
		{
			foreach my $skey (sort keys %{$conf{$key}})
			{
				printf("%s_%s='%s'\n",
					uc($key), uc($skey), sq($conf{$key}{$skey}));
			}
		}
		elsif (ref($conf{$key}) eq 'ARRAY')
		{
			printf("%s='", uc($key));

			my $first = 1;
			foreach my $val (@{$conf{$key}})
			{
				printf("%s%s", $first ? '' : ' ', sq($val));
				$first = 0;
			}

			printf("'\n");
		}
		else
		{
			printf("%s='%s'\n", uc($key), sq($conf{$key}));
		}
	}
}

1;
