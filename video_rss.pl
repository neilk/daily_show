#!/usr/local/bin/perl -w

# The Daily Show from comedy central publishes videos on their website.
# the videos are mixed with ads, and the HTML is often Firefox-hostile.
# this program will periodically look at the Daily show website to:

# - note when new videos are added
# - publish that info in RSS/Atom, as raw mms:// links.
# - videos or ads may be included in the feed but will 
#   appear precisely ONCE. so we must
#   also keep track of uris seen.
# - also publish a daily playlist, .m3u format, in a separate feed

use strict;

use lib '/home/brevity/lib/perl';

use LWP::RobotUA;
use HTML::TreeBuilder;
use XML::DOM;
use WWW::RobotRules;
use URI;
use Data::Dumper qw/Dumper/;
use XML::RSS::SimpleGen;
use NDBM_File;
use Fcntl; # for O_* constants
use File::Basename qw/dirname/;

use Getopt::Long;
my $DEBUG;
GetOptions("debug" => \$DEBUG);


# === config section

my $prog_dir = dirname($0);

my $host = "www.comedycentral.com";
my $recent_uri = "http://$host/mp/browseresults.jhtml?s=ds";

# a list of all the video files we've ever seen.
tie my %seen_metafile, 'NDBM_File', 
    "$prog_dir/seen.metafile", O_RDWR|O_CREAT, 0640 or die $!;

# a list of all the video 'frames' we've ever seen, which may
# contain one or more videos.
tie my %seen_frame,    'NDBM_File', 
    "$prog_dir/seen.frame",    O_RDWR|O_CREAT, 0640 or die $!;


rss_new($recent_uri, 'The Daily Show Videos (Unofficial)', 'Individual videos from ComedyCentral satirical news show');
rss_language('en');
rss_webmaster('neilk@brevity.org');
rss_daily();
my $rss_filepath = '/home/brevity/brevity.org/rss/daily_show_video.rss';


# === end config section



# gives us a rudimentary list of the the videos,
# plus links to frames which contain them

warn "getting links..." if $DEBUG;
my $videos = get_video_links($recent_uri);

# print Dumper $videos;


for my $v (@$videos) {

    warn "looking at $v->{'frame_uri'}" if $DEBUG;
    # the video is embedded with a metafile link (real or asf)
    my @metafile_uri = get_metafiles( $v->{'frame_uri'} )
	or warn "could not find metafiles in $v->{'frame_uri'}"; 
	
    for my $uri (@metafile_uri) { 
        
	next if ($seen_metafile{$uri});

	unless (is_ad($uri)) {
            rss_item( $uri, $v->{'title'}, $v->{'desc'} );
	}

        $seen_metafile{$uri} = 1;
    }        
}

unless (rss_item_count()) {
   exit 0;
}

rss_save ($rss_filepath, 7);





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
 
    my $parser = XML::DOM::Parser->new;
    my $doc = $parser->parse( get_content( $embed_uri ) );

    my @uri;
    for my $node (@{ $doc->getElementsByTagName('ref') }) {
        push @uri, $node->getAttributeNode('href')->getValue;
    }

    return @uri;
}



sub get_video_links {
    
    my ($recent_uri) = @_;
    warn "getting..." if $DEBUG;
    my $all_html = get_content($recent_uri);
    warn "got!" if $DEBUG;
    my $all_html_tree = HTML::TreeBuilder->new;
    $all_html_tree->parse($all_html);
    $all_html_tree->eof;
    
    # html links which will have embedded video
    # these are our primary id for video
    
    # expected: ... <span class="searchresult">
    #                   <a href="uri"><b>Title</b></a> -- description
    #               </span>
    
    my @video;
    SR: for my $sr (get_searchresult($all_html_tree)) {
        my ($uri_str, $title, $desc);
        for my $child ($sr->content_list) {
            if (ref $child) {
                if ($child->attr('_tag') eq 'a') { 
                    my $href = $child->attr('href');
                    my $uri = URI->new_abs($href,$recent_uri);
                    $uri_str = $uri->as_string;
                    next SR if $seen_frame{$uri_str};
 
                    my $bold = $child->look_down('_tag', 'b');
                    $title = $bold->as_text;
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
   
        # videos are in reverse-chron order, unshift to sort 
        unshift @video, { 'frame_uri' => $uri_str, 
                          'title' => $title, 
                          'desc' => $desc  };
        warn "got frame $uri_str\n" if $DEBUG;
        $seen_frame{$uri_str} = 1;
    }
    
    return \@video;
}

 


sub get_searchresult {
    my ($tree) = @_;
    return $tree->look_down(
        '_tag', 'span',
        sub {
            return unless $_[0]->attr('class') eq 'searchresult';
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
        };
        $ad_regex = join '|' => map { quotemeta($_) } @ad_keyword;
        $ad_regex = qr/(?:$ad_regex)/;
    }
    
    sub is_ad {
        return $_[0] =~ $ad_regex;
    }
    
}
    
