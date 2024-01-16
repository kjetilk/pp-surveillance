#!/usr/bin/env perl

use strict;
use warnings;

use JSON;

use Path::Tiny;
use List::Util qw(any);
use LWP::UserAgent;
use Term::ProgressBar;
use Config::Any;

use Data::Dumper;


# Will load multiple configs, but I assume that we have only one:
my $configfiles = \@ARGV;
my $cfg = Config::Any->load_files({files => $configfiles,
											  flatten_to_hash => 1 })->{$configfiles->[0]};

my $data = [];
if ($cfg->{'units_data'}) {
  my $file_ud = path($cfg->{'units_data'});
  $data = decode_json($file_ud->slurp);
}

my @sektorkoder = @{$cfg->{'sector_codes'}};

#print Dumper($data);
						  
my $ua = LWP::UserAgent->new(
									  agent => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36',
									  from => 'kjetil@kjernsmo.net',
    ssl_opts => { verify_hostname => 0 }
);

my @pages_to_try = ();
if ($cfg->{'page_list'}) {
  my $file_pl = path($cfg->{'page_list'});
  @pages_to_try = $file_pl->lines;
}

my %homepages;
my %tried;
my $i=0;
foreach my $org (@{$data}) {
  $i++;
  if (defined($org->{hjemmeside})
		&& defined($org->{institusjonellSektorkode}->{kode})
		&& (any { $org->{institusjonellSektorkode}->{kode} == $_ } @sektorkoder)) {
	 my $page = $org->{hjemmeside};
	 $page =~ s|/(.+)$||;
	 $page = 'https://' . $page;
	 push(@pages_to_try, $page);
  }
}

my $progress = Term::ProgressBar->new ({count => scalar(@pages_to_try)});

foreach my $page (@pages_to_try) {
  chomp($page);
  my $url = URI->new($page);
  unless ( $tried{$url->canonical}) {
	 my $res = $ua->get($url);
	 warn $page . " " .$res->code;
	 $tried{$url->canonical} = 1;
	 if ($res->is_success) {
		$homepages{$page} = 1;
		if ($cfg->{'content_dir'}) {
		  my $dir = path($cfg->{'content_dir'}, $url->authority)->mkdir;
		  $dir->path('content.html')->spew_utf8($res->decoded_content);
		}
	 }
  }
  $progress->update($i);
}

print join("\n", keys(%homepages));
