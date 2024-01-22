#!/usr/bin/env perl

use strict;
use warnings;

use JSON;

use Path::Tiny;
use List::Util qw(any);
use LWP::UserAgent;
use Term::ProgressBar;
use Config::Any;
use DBI;
use SQL::Abstract;
use Switch;

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

my $dbh = DBI->connect(@{$cfg->{'dbi_config'}}, {AutoCommit => 1, mysql_enable_utf8 => 1});
my $sql = SQL::Abstract->new;

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

my $uab = LWP::UserAgent->new(
									  from => 'kjetil@kjernsmo.net',
									  ssl_opts => { verify_hostname => 0 }
									 );

foreach my $page (@pages_to_try) {
  my $url = URI->new($page);
  unless ( $tried{$url->canonical}) {
	 my $res = $ua->get($url);
	 $tried{$url->canonical} = 1;
	 if ($res->is_success) {
		my $content_file_str = '';
		if ($cfg->{'content_dir'}) {
		  my $dir = path($cfg->{'content_dir'}, $url->authority)->mkdir;
		  my $content_file = $dir->path('content.html');
		  $content_file->spew_utf8($res->decoded_content);
		  $content_file_str = $content_file->absolute->canonpath;
		}
		my $blres = $uab->post($cfg->{'blacklight_api'},
									  'Content-Type' => 'application/json',
									  Content => '{ "inUrl": "'.$url.'", "location": "EU", "device": "desktop" }');
		my $ins = decode_json($blres->decoded_content);
		my %inserts = (
							'run_id' => 1,
							'site' => "$url",
							'status' => $ins->{'status'},
							'dest' => $ins->{'uri_dest'},
							'num_third_party_requests' => scalar @{$ins->{'hosts'}->{'requests'}->{'third_party'}},
							'data_archive' => $content_file_str
						  );
		
		# Find correct cards
		my @cards;
		foreach my $group (@{$ins->{'groups'}}) {
		  if ($group->{'title'} eq 'Blacklight Inspection Result') {
			 @cards = @{$group->{'cards'}};
			 last;
		  }
		}
		die "Couldn't find reportcards" unless @cards;

		foreach my $card (@cards) {
		  switch($card->{'cardType'}) {
			 case 'ddg_join_ads'
				{ $inserts{'num_ad_trackers'} = $card->{'bigNumber'} };
			 case 'cookies'
				{ $inserts{'num_third_party_cookies'} = $card->{'bigNumber'} };
			 case 'canvas_fingerprinters'
				{ $inserts{'found_fingerprinting'} = $card->{'testEventsFound'} };
			 case 'session_recorders'
				{ $inserts{'found_session_recording'} = $card->{'testEventsFound'} };
			 case 'key_logging'
				{ $inserts{'found_keylogging'} = $card->{'testEventsFound'} };
			 case 'fb_pixel_events'
				{ $inserts{'found_facebook_pixel'} = $card->{'testEventsFound'} };
			 case 'ga'
				{ $inserts{'found_ga_remarketing'} = $card->{'testEventsFound'} };
		  }
		}

		my($stmt, @bind) = $sql->insert('sitevisits', \%inserts);
		warn $stmt;
		warn Dumper \@bind;

 		my $sth = $dbh->prepare($stmt) or die $dbh->errstr;;
 		$sth->execute(@bind);

		
	 }
  }
  $progress->update($i);
}

$dbh->disconnect;

1;
