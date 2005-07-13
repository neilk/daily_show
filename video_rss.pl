#!/usr/local/bin/perl -w

# The Daily Show from comedy central publishes frames on their website.
# the frames are mixed with ads, and the HTML is often Firefox-hostile.
# this program will periodically look at the Daily show website to:

# - note when new frames are added
# - publish that info in RSS/Atom, as raw mms:// links.
# - frames or ads may be included in the feed but will 
#   appear precisely ONCE. so we must
#   also keep track of uris seen.
# - also publish a daily playlist, .m3u format, in a separate feed

use strict;

use lib '/home/brevity/lib/perl';

use LWP::RobotUA;
use HTML::TreeBuilder;
use XML::DOM;
use XML::RSS::SimpleGen; # rss_* functions
use WWW::RobotRules;
use URI;
use Data::Dumper qw/Dumper/;
use Tie::File;
use Tie::Record;
use File::Basename qw/dirname/;
use POSIX qw/strftime/;

use Getopt::Long;
my $DEBUG;
GetOptions("debug" => \$DEBUG);


# === config section

my $prog_dir = dirname($0);
my $prog_run_time = strftime('%Y-%m-%d %H:%M:%S', localtime);

my $recent_uri = "http://www.comedycentral.com/sitewide/media_player/browseresults.jhtml?showId=934";

# a list of all the video or flash or whatever files we've ever seen.
tie my @seen_metafile, 'Tie::Record', 
    "$prog_dir/seen.metafile.txt",
    fields => 'time link title description', 
    or die $!;

# a list of all the frames we've ever seen, which may
# contain one or more frames.
tie my @seen_frame, 'Tie::File', 
    "$prog_dir/seen.frame.txt",
    or die $!;
    

rss_new($recent_uri, 'The Daily Show Videos (Unofficial)', 'Clips of the satirical news show from ComedyCentral.com');
rss_language('en');
rss_webmaster('neilk@brevity.org');
rss_daily();
my $rss_filepath = '/home/brevity/brevity.org/rss/daily_show_video.rss';

my $keep_item_count = 10;

# === end config section


# ===== MAIN ===========

# what is invisible here is how the subroutines communicate via
# the global, which is a tied file and thus always recording 
# to disk

my ($new_item_count) = get_new_items($recent_uri);
$new_item_count or exit 0;

update_rss($rss_filepath, $new_item_count);
# write_playlist($items); # TODO; second rss file, so will have to abandon SimpleGen.

exit 0;

# ======================




sub get_new_items {

    warn "getting links..." if $DEBUG;
    my ($recent_uri) = @_;
    my @frame = @{ get_frame_links($recent_uri) };

    my $new_item_count;
    
    
    my %seen_metafile = map { $_->{'link'} => 1 } @seen_metafile;
    
    for my $f (@frame) {
    
        warn "looking at $f->{'frame_uri'}" if $DEBUG;
        # the frame is embedded with a metafile link (real or asf)
	# assume asf, all the new ones are asf.
        my @metafile_uri = get_metafiles( $f->{'frame_uri'} )
    	or warn "could not find metafiles in $f->{'frame_uri'}"; 
    	
	warn "metafile_uri: @metafile_uri\n" if $DEBUG;
	
        for my $uri (@metafile_uri) { 
            next if ($seen_metafile{$uri});
    
    	    unless (is_ad($uri)) {
	        warn "new item! $uri\n" if $DEBUG;
		# create data structure similar to parsed RSS, so
		# we can update more easily.
                push @seen_metafile,
		     { 'title'        => $f->{'title'},
		       'description'  => $f->{'desc'},
		       'link'         => $uri,           
		       'time'         => $prog_run_time,
		     };
	        $new_item_count++;
	    }
   
   
        }        
        
	push @seen_frame, $f->{'frame_uri'};

    }
    
    return $new_item_count;

}



sub update_rss {
    my ($file, $new_item_count) = @_;
    
    # if there are a LOT of new items, show them all.
    # otherwise show the new items, and as many of the old ones
    # as needed to make up $keep_item_count
    
    my $count = $keep_item_count;
    if ($new_item_count > $count) {
        $count = $new_item_count;
    }
    
    if ($count > @seen_metafile) {
        $count = scalar @seen_metafile;
    }
    
    for my $it (@seen_metafile[ -1*$count .. -1 ]) {
	rss_item( @{$it}{qw/link title description/} );
    }
	
    rss_save ($file, 7);
}



sub get_metafiles {
    my ($uri) = @_;
    my $tree = HTML::TreeBuilder->new;
    $tree->parse( get_content( $uri ) );
    $tree->eof;

    my $embed = $tree->look_down( '_tag', 'embed' );
    if (not defined $embed) {
         warn "$uri has no embed tag";
         return ();
    }
    my $embed_uri = $embed->attr('src');
 
    my @uri;
    
    eval { 
    	my $parser = XML::DOM::Parser->new;
    	my $doc = $parser->parse( get_content( $embed_uri ) );

    	for my $node (@{ $doc->getElementsByTagName('ref') }) {
            my $href = $node->getAttributeNode('href')->getValue;
	    # there are 'spacer' insterstitials, usually flash or gifs
	    if ($href =~ /(wmv|mov|qt|mpg)$/) {
               push @uri, $href;
	    }
        }
    };
    warn $@ if $@;

    return @uri;
}



sub get_frame_links {
    
    my ($recent_uri) = @_;
    warn "getting..." if $DEBUG;
    my $all_html = get_content($recent_uri);
    warn "got!" if $DEBUG;
    my $all_html_tree = HTML::TreeBuilder->new;
    $all_html_tree->parse($all_html);
    $all_html_tree->eof;
    
    # html links which will have embedded frame
    # these are our primary id for frame
    
    # expected: ... <td class="results_desc">
    #                  <a class="results_title" target="_top" href="uri">
    #                     Title
    #                  </a>
    #                  -- description
    #               </td>
    
    my %seen_frame = map { $_ => 1 } @seen_frame;
    
    my @frame;
    SR: for my $sr (get_searchresult($all_html_tree)) {
        my ($uri_str, $title, $desc);
        for my $child ($sr->content_list) {
            if (ref $child) {
                if ($child->attr('_tag') eq 'a') { 
                    my $href = $child->attr('href');
                    my $uri = URI->new_abs($href,$recent_uri);
                    $uri_str = $uri->as_string;
                    next SR if $seen_frame{$uri_str};
                    $title = $child->as_text;
                }
            } else {
                $desc .= $child;
            }
        } 
 
        for ($title, $desc) {
            $_ =~ s/[\x80-\xff]//g; # let's pretend it's just ascii!
            $_ =~ s/^[-\s]+|\s+$//g; # strip leading or trailing whitespace, 
                                     # dashes at start.
        }      
   
        # frames are in reverse-chron order, unshift to sort 
        unshift @frame, { 'frame_uri' => $uri_str, 
                          'title' => $title, 
                          'desc' => $desc  };
        warn "got frame $uri_str\n" if $DEBUG;
    }
    
    return \@frame;
}

 


sub get_searchresult {
    my ($tree) = @_;
    return $tree->look_down(
        '_tag', 'td',
        sub {
	    my $class = $_[0]->attr('class');
            return unless defined $class and $class eq 'results_desc';
        }
    );
}




# whenever we get content, use LWP::RobotUA so we
# a) don't flood the server
# b) obey robots.txt.

{

    # separate robot for each host, to follow robots.txt rules.
    my %ua_host; 
    
    sub ua {
       my ($host) = @_;
       
       return $ua_host{$host} if $ua_host{$host};
       
       my $ua = LWP::RobotUA->new('DailyShowWatcher/0.1',
                                  'neilk@brevity.org');
       $ua->delay(0) if $DEBUG;

       my $robot_rules = WWW::RobotRules->new('DailyShowWatcher/0.1');
       my $robot_rules_uri = "http://$host/robots.txt";
       my $response = $ua->get($robot_rules_uri);
       if ($response->is_success) {
           $robot_rules->parse( $robot_rules_uri, $response->content);
           $ua->rules($robot_rules);
       }

       $ua_host{$host} = $ua;
    }

}

sub get_content {
    my ($uri) = @_;
    
    my $ua = ua(URI->new($uri)->host);
	
    my $response = $ua->get($uri);
    if ($response->is_success) {
        return $response->content;
    }
    die "couldn't get <$uri>: " . $response->status_line;
}   



{
    my $ad_regex;
    BEGIN {
        my @ad_keyword = qw{
            /ads/
            TDS_image_cabinet 
            goodwrench
            house_ad
	    .swf
	    doubleclick.net
        };
        $ad_regex = join '|' => map { quotemeta($_) } @ad_keyword;
        $ad_regex = qr/(?:$ad_regex)/;
    }
    
    sub is_ad {
        return $_[0] =~ $ad_regex;
    }
    
}
    
