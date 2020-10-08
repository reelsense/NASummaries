#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
use Term::ANSIColor qw(:constants);
$Term::ANSIColor::AUTORESET = 1;
use Getopt::Long;
use POSIX;
use File::Copy;
use HTML::Entities;

my $usage = <<END;
USAGE: $0 [-hnpv] [-m MAIL [-m MAIL2...]] [-x SYS]

Reads NASummaries.txt, produce derivative HTML and/or LaTeX files,
  and optionally upload them to a webserver.

    -a, --art           Include album art in PDF and HTML
    -b, --book          Use LaTeX book class instead of report
    -d, --delete        Delete LaTeX files after rendering PDF
    -f, --frontmatter   Suppress the frontmatter
    -g, --git           Commit and push to repo
    -h, --help          Print this summary and exit
    -H, --HTML          Create HTML
    -i, --input         Read from argument instead of NASummaries.txt
    -l, --latex         Create LaTeX
    -n, --number        Use this number as the Show number in the git commit
    -N, --noop          Do not execute rsync or git that would touch a remote site
    -r, --reedit        Indicate reedits in the LaTeX
    -t, --title         Suppress the title page
    -u, --upload        rsync to callclooney.org
    -v, --verbose       Print upload and git commands before executing them
END

my ($opt_art, $opt_book, $opt_delete, $opt_frontmatter, $opt_git, $opt_help,
    $opt_HTML, $opt_input, $opt_latex, $opt_number, $opt_noop, $opt_reedit,
    $opt_title, $opt_upload, $opt_verbose);

Getopt::Long::Configure ('bundling');
die 'Terminating' unless GetOptions('a|art' => \$opt_art,
           'b|book' => \$opt_book,
           'd|delete' => \$opt_delete,
           'f|frontmatter' => \$opt_frontmatter,
           'g|git' => \$opt_git,
           'h|?' => \$opt_help,
           'H|HTML' => \$opt_HTML,
           'i|input:s' => \$opt_input,
           'l|latex' => \$opt_latex,
           'n|number:i' => \$opt_number,
           'N|noop' => \$opt_noop,
           'r|reedit' => \$opt_reedit,
           't|title' => \$opt_title,
           'u|upload' => \$opt_upload,
           'v|verbose+' => \$opt_verbose);

print "Verbosity $opt_verbose\n" if $opt_verbose;
die "$usage\n\n" if $opt_help;

my $maxShowNumber = 0;
my $summaries = ReadSummaries($opt_input);
my $latexFile;
InitialSetup();
if ($opt_HTML)
{
  WriteIndexHTML();
  foreach my $summary (@$summaries)
  {
    GetAlbumArt($summary);
    WriteHTMLPage($summary);
  }
  WriteSitemap();
}
my $latexFileName = 'NASummaries.tex';
if ($opt_latex)
{
  open $latexFile, '>:encoding(UTF-8)', $latexFileName;
  LatexHeader();
  my $nobreak = 0;
  foreach my $summary (@$summaries)
  {
    GetAlbumArt($summary);
    LatexSection($summary, $nobreak);
    $nobreak = ($summary->{'nobreak'})? 1:0;
  }
  print $latexFile '\end{document}'. "\n";
  close $latexFile;
  my $cmd = "xelatex -output-directory=na -halt-on-error $latexFileName";
  print BLUE "$cmd\n" if $opt_verbose;
  my $output = `$cmd`;
  if ($?)
  {
    print BOLD RED "$output\n";
    exit($?);
  }
  if ($opt_art)
  {
    $output =`$cmd`;
    if ($?)
    {
      print BOLD RED "$output\n";
      exit($?);
    }
  }
  unless ($opt_title)
  {
    $cmd = 'xelatex -halt-on-error Title.tex';
    print BLUE "$cmd\n" if $opt_verbose;
    $output = `$cmd`;
    if ($?)
    {
      print BOLD RED "$output\n";
      exit($?);
    }
    $cmd = 'gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite'.
           ' -sOutputFile=na/NASummariesTitled.pdf'.
           ' Title.pdf na/NASummaries.pdf';
    print BLUE "$cmd\n" if $opt_verbose;
    `$cmd`;
    File::Copy::copy('na/NASummariesTitled.pdf', 'na/NASummaries.pdf');
  }
  $cmd = 'gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dNOPAUSE'.
         ' -dQUIET -dBATCH -sOutputFile=na/NASummariesSmall.pdf'.
         ' na/NASummaries.pdf';
  print BLUE "$cmd\n" if $opt_verbose;
  #`$cmd`;
  #rename('na/NASummariesSmall.pdf', 'na/NASummaries.pdf');
  if ($opt_delete)
  {
    unlink $latexFileName;
    unlink 'na/NASummaries.aux';
    unlink 'na/NASummaries.log';
    unlink 'na/NASummaries.out';
    unlink 'na/NASummaries.idx';
    unlink 'na/NASummaries.ilg';
    unlink 'na/NASummaries.ind';
    unlink 'Title.log';
    unlink 'Title.aux';
  }
}
Git() if $opt_git;
Upload() if $opt_upload;

# Returns arrayref of shows, in order of most recent to oldest.
# Show is hashref with the following fields:
# 'number' => show number
# 'title' => title string
# 'date' => Date reformatted if necessary into YYYY-MM-DD form
# 'artwork' => Boolean for artwork display at bottom of LaTeX page
# 'nobreak' => Boolean for no page break between this and next summary
# 'reedited' => Boolean if one of the early summaries has been reedited.
# 'lines' => arrayref of timestamped lines in order.
sub ReadSummaries
{
  my $file = shift || 'NASummaries.txt';

  my @retval;
  open my $in, '<:encoding(UTF-8)', $file;
  undef $/;
  my $summaries = <$in>;
  close $in;
  my @summaries = split m/\n\n+/, $summaries;
  @summaries = reverse @summaries;
  foreach my $summary (@summaries)
  {
    my $i = 0;
    push @retval, {'lines' => []};
    my @lines = split "\n", $summary;
    foreach my $line (@lines)
    {
      chomp $line;
      if ($i == 0)
      {
        $retval[-1]->{'number'} = $line;
        $retval[-1]->{'file'} = $line. '_NASummary.html';
        $retval[-1]->{'url'} = 'https://www.blugs.com/na/'. $line. '_NASummary.html';
        $maxShowNumber = $line unless $maxShowNumber > $line;
      }
      elsif ($i == 1)
      {
        $line =~ s/(\d+)\/(\d+)\/(\d+)/$3-$1-$2/;
        $retval[-1]->{'date'} = $line;
      }
      elsif ($i == 2)
      {
        $retval[-1]->{'title'} = $line;
      }
      else
      {
        if ($line !~ m/^\d/)
        {
          $retval[-1]->{'reedited'} = 1 if $line eq 'Reedited';
          $retval[-1]->{'nobreak'} = 1 if $line eq 'Nobreak';
          $retval[-1]->{'artwork'} = 1 if $line eq 'Artwork';
        }
        else
        {
          # Extract timestamp from initial quote
          if ($line =~ m/^0:00:00\s[A-Z][A-Z][A-Z].*?\((\d:\d\d:\d\d)\)$/)
          {
            $retval[-1]->{'timestamp'} = $1;
						#\usepackage[overlap, latin]{ruby}
            #\renewcommand{\rubysize}{0.75}
            #\renewcommand{\rubysep}{-0.1ex}
            # \item[\ruby{\href{https://www.noagendaplayer.com/listen/563/0-00-00}{\scmono{0:00:00}}}{\href{https://www.noagendaplayer.com/listen/563/0-00-00}{\scmono{1:23:45}}}]JCD: ``When Puff the Magic Dragon shows up then I'll listen to your crappy argument!"
          }
          push @{$retval[-1]->{'lines'}}, $line;
        }
      }
      $i++;
    }
  }
  return \@retval;
}


# Create na/ and na/art/ directories if necessary.
# Copy CSS and PDF icon image from git repo.
sub InitialSetup
{
  mkdir 'na' unless -d 'na';
  mkdir 'na/art' unless -d 'na/art';
  File::Copy::copy 'na.css', 'na/na.css';
  File::Copy::copy 'pdf-icon.png', 'na/pdf-icon.png';
}

sub WriteIndexHTML
{
  open my $index, '>:encoding(UTF-8)', 'na/index.html';
  my $html = HTMLHeader('No Agenda Show Summaries');
  print $index $html. "\n";
  $html = <<'END';
<h1>No Agenda Show Summaries
  <a rel="license" href="http://creativecommons.org/publicdomain/zero/1.0/">
    <img src="https://i.creativecommons.org/p/zero/1.0/88x31.png" style="border-style: none;" alt="CC0"/>
  </a>
</h1>
<h4>Shut up, slave!</h4>
<hr/>
END
  print $index $html;
  foreach my $summary (@$summaries)
  {
    $html = sprintf '<a href="%s"><strong>%s</strong> (%s) <i>%s</i></a><br/>',
                       $summary->{'file'}, $summary->{'number'}, $summary->{'date'},
                       HTML::Entities::encode_entities($summary->{'title'});
    print $index $html. "\n";
  }
  # three divs: container, content, main
  print $index "</div></div></div></body></html>\n";
}

sub WriteHTMLPage
{
  my $summary = shift;

  my $n = $summary->{'number'};
  open my $page, '>:encoding(UTF-8)', 'na/'. $summary->{'file'};
  my $html = HTMLHeader('No Agenda '. $n, $n);
  print $page $html;
  $html = sprintf '<h3>%s <b>%s</b> <span style="font-size:.6em;">(%s)</span></h3>',
                   $n, HTMLEscape($summary->{'title'}), $summary->{'date'};
  print $page $html;
  my $url = AlbumArtURL($summary);
  if ($url)
  {
    print $page '<div style="text-align:center;">';
    print $page '<img style="max-width:40em;" alt="Show '. $n.
                ' album art" src="'. $url. '"/></div>';
  }
  print $page "<table>\n";
  foreach my $line (@{$summary->{'lines'}})
  {
    my @parts = split m/\s+/, $line, 2;
    my $line = HTMLEscape($parts[1]);
    my $urltime = $parts[0];
    $urltime =~ s/:/-/g;
    my $label = sprintf '<a href="https://www.noagendaplayer.com/listen/%s/%s" target="_blank">%s</a>',
                        $n, $urltime, $parts[0];
    print $page sprintf '<tr><td style="padding-right:5px;vertical-align:top;"><code>%s</code></td><td>%s</td></tr>',
                        $label, $line;
    print $page "\n";
  }
  print $page '</table></div></div></div></body></html>'. "\n";
  close $page;
}

sub AlbumArtURL
{
  my $summary = shift;

  my $url;
  my $filename = AlbumArtFilename($summary);
  if (-f 'na/art/'. $filename)
  {
    $url = 'art/'. $filename;
  }
  return $url
}

# Art Generator has accepted art from 209 to 1084
# For newer shows use the shownotes -- let's say post 1000
# https://noagendaartgenerator.com/episode/1036
# <img src="/assets/artwork/episode/1004/1OzBMDkib9.png">
# Some are missing: <img src="/assets/img/artplaceholder512.jpg">
# Art Generator node numbers are off by one from show number.
sub GetAlbumArt
{
  my $summary = shift;

  my $n = $summary->{'number'};
  my $filename = AlbumArtFilename($summary);
  unless (-f 'na/art/'. $filename)
  {
    my $arturl;
    if ($n >= 1000)
    {
      my $url = ShowNotesURL($n);
      my $cmd = 'curl -L -A "Mozilla/5.0 (Windows; U; Windows NT 5.1; de; rv:1.9.2.3)'.
                ' Gecko/20100401 Firefox/3.6.3" --compressed '. $url;
      print BLUE "$cmd\n" if $opt_verbose;
      my $html = `$cmd`;
      if ($html =~ m!(https?://.+?/enc/.+?-art-big.png)!)
      {
        $arturl = $1;
      }
    }
    elsif ($n >= 209)
    {
      my $url = 'https://noagendaartgenerator.com/episode/'. ($n + 1);
      my $cmd = 'curl -L -A "Mozilla/5.0 (Windows; U; Windows NT 5.1; de; rv:1.9.2.3)'.
                ' Gecko/20100401 Firefox/3.6.3" '. $url;
      print BLUE "$cmd\n" if $opt_verbose;
      my $html = `$cmd`;
      if ($html =~ m/acceptedartwork(.+?)<\/div>/si)
      {
        my $snippet = $1;
        if ($snippet =~ m!<img src="(.+?\.png)"!)
        {
          print "Got img url $1\n";
        }
        $arturl = 'https://noagendaartgenerator.com/'. $1;
      }
    }
    my $cmd = 'curl '. $arturl. ' -o na/art/'. $filename;
    print BLUE "$cmd\n" if $opt_verbose;
    print `$cmd`;
    die sprintf "Can't get album art at %s", defined ($arturl)? $arturl : '<undef>' unless -f 'na/art/'. $filename;
  }
}

sub AlbumArtFilename
{
  my $summary = shift;

  my $n = $summary->{'number'};
  my $file = $n. '.png';
  $file =~ s/\.(\d+\.png)/_$1/g;
  return $file;
}

sub WriteSitemap
{
  my $now = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
  open my $sitemap, '>:encoding(UTF-8)', 'na/sitemap.xml';
  my $xml = <<END;
<?xml version="1.0" encoding="UTF-8"?>
<urlset
      xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://www.sitemaps.org/schemas/sitemap/0.9
            http://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd">
  <url>
    <loc>https://www.blugs.com/na/index.html</loc>
    <lastmod>$now</lastmod>
    <changefreq>daily</changefreq>
  </url>
  <url>
    <loc>https://www.blugs.com/na/NASummaries.pdf</loc>
    <lastmod>$now</lastmod>
    <changefreq>daily</changefreq>
  </url>
END
  print $sitemap $xml;
  foreach my $summary (@$summaries)
  {
    my $url = $summary->{'url'};
    $xml = <<END;
  <url>
    <loc>$url</loc>
    <lastmod>$now</lastmod>
    <changefreq>daily</changefreq>
  </url>
END
    print $sitemap $xml;
  }
  print $sitemap $xml. "</urlset>\n";
}

sub HTMLEscape
{
  my $s = shift;

  $s =~ s/\\_/_/g;
  $s =~ s/\s\s+/<br\/>/g;
  $s =~ s/\*\*(.+?)\*\*/<b>$1<\/b>/g;
  $s =~ s/\*(.+?)\*/<i>$1<\/i>/g;
  $s =~ s/&amp;ast;/*/g;
  $s =~ s/~~~(.+?)~~~/<span style="background:black">&nbsp;&nbsp;&nbsp;&nbsp;<\/span>/g;
  $s =~ s/~~(.+?)~~/<s>$1<\/s>/g;
  $s =~ s/``(.+?)``/<code>$1<\/code>/g;
  $s =~ s/`(.+?)`/<code>$1<\/code>/g;
  $s =~ s/`/&lsquo;/g;
  $s =~ s/'/&rsquo;/g;
  $s =~ s/\[\]/ /g;
  $s =~ s/\[\[(\[*.+?\]*)\]\]/$1/g;
  $s =~ s/\\{/{/g;
  $s =~ s/\\}/}/g;
  #$s =~ s/\\(\'+)/$1/g
  $s =~ s/__(.+?)__/$1/g;
  $s =~ s/(\d+@\d:\d\d:\d\d)/PlayerURL($1, 'html')/ge;
  $s =~ s/\((\d:\d\d:\d\d)\)/(<code>$1<\/code>)/g;
  $s =~ s/<frac>(.+?)\/(.+?)<\/frac>/<sup>$1<\/sup>&frasl;<sub>$2<\/sub>/g;
  $s =~ s/--/&mdash;/g;
  my $new = '';
  my $oq;
  my @chars = split m//, $s;
  foreach my $char (@chars)
  {
    if ($char eq '"')
    {
      unless ($oq)
      {
        $char = '&ldquo;';
        $oq = 1;
      }
      else
      {
        $char = '&rdquo;';
        $oq = 0;
      }
    }
    $new .= $char;
  }
  $s = $new;
  $s =~ s/\((B?CotD)\)/(<span style="color:red;">$1<\/span>)/g;
  $s =~ s/\(((ACC|JCD)PPotD)\)/(<span style="color:red;">$1<\/span>)/g;
  $s =~ s/\((TCS)\)/(<span style="color:red;">$1<\/span>)/g;
  return $s
}

sub PlayerURL
{
  my $s   = shift;
  my $fmt = shift;

  my $label = $s;
  my @parts = split /\s*@\s*/, $s, 2;
  my $shownum = $parts[0];
  my $urltime = $parts[1];
  $urltime =~ s/:/-/g;
  if ($fmt eq 'latex')
  {
    $label = sprintf "\\href{https://www.noagendaplayer.com/listen/%s/%s}{\\scmono{$s}}",
                     $shownum, $urltime;
  }
  else
  {
    $label = sprintf "<a href='https://www.noagendaplayer.com/listen/%s/%s' target='_blank'><code>$s</code></a>",
                     $shownum, $urltime;
  }
  return $label;
}

sub HTMLHeader
{
  my $title = shift;
  my $showNumber = shift;

  my $googleDiv = <<'END';
<div>
  <script type="text/javascript">
    (function() {
      var cx = '000307461187542395848:qdygkg6ssbo';
      var gcse = document.createElement('script');
      gcse.type = 'text/javascript';
      gcse.async = true;
      gcse.src = (document.location.protocol == 'https:' ? 'https:' : 'http:') +
          '//www.google.com/cse/cse.js?cx=' + cx;
      var s = document.getElementsByTagName('script')[0];
      s.parentNode.insertBefore(gcse, s);
    })();
  </script>
  <div class="gcse-search"></div>
</div>
END
  my $showNotesLink = '';
  my $homeLink = '';
  if (defined $showNumber)
  {
    $googleDiv = '';
    $homeLink = '<li><a href="index.html">Home</a></li>';
    my $showNotesURL = ShowNotesURL($showNumber);
    $showNotesLink = '<li><a href="'. $showNotesURL. '" target="_blank">Show Notes</a></li>' if defined $showNotesURL;
  }
  my $html = <<END;
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
  <link rel="stylesheet" type="text/css" media="all" href="na.css"/>
  <title>$title</title>
</head>
<body>
$googleDiv
<div class="container">
  <div class="header">
    <h1 class="header-heading">Call Clooney!</h1>
  </div>
  <div class="nav-bar">
    <ul class="nav">
      $homeLink
      $showNotesLink
      <li><a href="http://noagendashow.com">No Agenda Show</a></li>
      <li><a href='https://github.com/K8TIY/NASummaries'>Github</a></li>
      <li><a href="NASummaries.pdf"><img alt="PDF" src="pdf-icon.png" width="20" height="20"/>   Full PDF</a></li>
    </ul>
  </div>
  <div class="content">
    <div class="main">
END
  return $html;
}

sub ShowNotesURL
{
  my $showNumber = shift;

  return 'http://'. $showNumber. '.noagendanotes.com' if $showNumber > 581;
  return 'http://'. $showNumber. '.nashownotes.com' if $showNumber > 300;
}

sub LatexHeader
{
  if ($opt_book)
  {
    print $latexFile <<'END';
\documentclass[twoside]{book}
\usepackage{fancyhdr}
\pagestyle{fancy}
\fancyhf{}
\fancyhead[LE,RO]{\thepage}
\fancyhead[LO,RE]{}
\renewcommand{\headrulewidth}{0pt}
END
  }
  else
  {
    print $latexFile '\documentclass{report}'. "\n";
  }
  print $latexFile <<'END';
\usepackage{tikz}
\usepackage{graphicx}
\usepackage{fontspec}
\usepackage{fancyvrb}
\usepackage{enumitem}
\usepackage[normalem]{ulem}
\usepackage{censor}
\usepackage[colorlinks=true]{hyperref}
\setlist{nolistsep}
\setlist{noitemsep}
\usepackage{dblfloatfix}
\usepackage{marginnote}
\newcommand{\mono}[1]{{\fontspec{Courier}#1}}
\newcommand{\scmono}[1]{{\fontspec{Source Code Pro}#1}}
\newcommand{\emoji}[1]{{\fontspec[Scale=0.9]{Hiragino Sans W1}#1}}
\newcommand{\cjk}[1]{{\fontspec[Scale=0.9]{Kaiti TC}#1}}
\newcommand{\asymbol}[1]{{\fontspec[Scale=0.9]{Apple Symbols}#1}}
\newcommand{\lgrande}[1]{{\fontspec[Scale=0.9]{Lucida Grande}#1}}
\newcommand{\skt}[1]{{\fontspec[Scale=0.9]{Sanskrit 2003}#1}}
\addtolength{\oddsidemargin}{-.6in}
\addtolength{\evensidemargin}{-.6in}
\addtolength{\textwidth}{1.2in}
\setlength{\parindent}{0pt}
\usepackage{titlesec}
%\titleformat{\section}[display]{\large}{\thetitle}{1em}{#1\space\xrfill[0.6ex]{0.4pt}}
\renewcommand*\thesection{\arabic{section}}
\newcommand{\doulos}[1]{{\fontspec{Doulos SIL}#1}}
\begin{document}
END
  if ($opt_book && !$opt_frontmatter)
  {
    print $latexFile '\include{Frontmatter}'. "\n". '\mainmatter'. "\n";
  }
  elsif (!$opt_frontmatter)
  {
    print $latexFile '\textit{The text of this document and associated software'.
                     ' are hereby placed in the public domain. All image copyrights'.
                     ' belong to their respective owners.}'. "\n". '\newpage'. "\n";
  }
}

sub LatexSection
{
  my $summary = shift;
  my $samepage = shift;

  my $n = $summary->{'number'};
  print $latexFile sprintf '\renewcommand{\thesection}{%s}%s', $n, "\n";
  my $pic = 'na/art/'. AlbumArtFilename($summary);
  $pic = undef unless -f $pic;
  my $filler;
  my $title = $summary->{'title'};
  if ($opt_reedit && $summary->{'reedited'})
  {
    $title .= " \x2713";
  }
  $title = LatexEscape($title);
  print $latexFile sprintf "\\section[%s]{%s \\small{(%s)}\n", $title, $title, $summary->{'date'};
  if ($opt_art && defined $pic)
  {
    if ($summary->{'artwork'})
    {
      $filler = $pic;
    }
    else
    {
      if (!$samepage)
      {
        print $latexFile <<END;
\\begin{tikzpicture}[remember picture,overlay]
\\node[xshift=4cm,yshift=-2.3cm] at (current page.north west)
{\\includegraphics[width=3cm,height=3cm,keepaspectratio]{$pic}};
\\end{tikzpicture}
END
      }
      else
      {
        print $latexFile <<END;
\\begin{tikzpicture}[remember picture,overlay]
\\node[xshift=-4.6cm,yshift=-2.3cm] at (current page.north east)
{\\includegraphics[width=3cm,height=3cm,keepaspectratio]{$pic}};
\\end{tikzpicture}
END
      }
    }
  }
  print $latexFile "}\n";
  print $latexFile "\\begin{itemize}\n";
  foreach my $line (@{$summary->{'lines'}})
  {
    my @parts = split m/\s+/, $line, 2;
    my $label = sprintf '\scmono{%s}', $parts[0];
    my $urltime = $parts[0];
    $urltime =~ s/:/-/g;
    $label = sprintf '\href{https://www.noagendaplayer.com/listen/%s/%s}{%s}', $n, $urltime, $label;
    print $latexFile sprintf "\\item[%s]%s\n", $label, LatexEscape($parts[1]);
  }
  print $latexFile "\\end{itemize}\n";
  if ($filler)
  {
    print $latexFile "\\begin{figure*}[!b]\\begin{center}\\includegraphics[width=.45 \\textwidth,height=.45 \\textheight,keepaspectratio]{$pic}\\end{center}\\end{figure*}";
  }
  if ($summary->{'nobreak'})
  {
    print $latexFile "\\vspace{.25cm}\n";
  }
  else
  {
    print $latexFile "\\newpage\n";
  }
}

# Educate quotes and format stuff
sub LatexEscape
{
  my $s = shift;

  $s =~ s/\s\s+/\\\\/g;
  $s =~ s/([#%&\$])/\\$1/g;
  $s =~ s/\*\*(.+?)\*\*/\\textbf{$1}/g;
  $s =~ s/\*(.+?)\*/\\textit{$1}/g;
  $s =~ s/~~~(.+?)~~~/\\censor{abcdefg}/g;
  $s =~ s/~~(.+?)~~/\\sout{$1}/g;
  $s =~ s/(\d+@\d:\d\d:\d\d)/PlayerURL($1, 'latex')/ge;
  $s =~ s/(\d:\d\d:\d\d)/\\scmono{$1}/g;
  $s =~ s/\x60\x60(.+?)\x60\x60/\\scmono{$1}/g;
  $s =~ s/`(.+?)`/\\texttt{$1}/g;
  $s =~ s/\[\[(\[*.+?\]*)\]\]/\\doulos{$1}/g;
  $s =~ s/\[\]/\\ /g;
  $s =~ s/\[/{\\lbrack}/g;
  $s =~ s/\]/{\\rbrack}/g;
  $s =~ s/([\N{U+0180}-\N{U+024F}]+)/\\doulos{$1}/g;
  $s =~ s/([\N{U+0250}-\N{U+02FF}]+)/\\doulos{$1}/g;
  $s =~ s/([\N{U+0400}-\N{U+052F}]+)/\\doulos{$1}/g;
  $s =~ s/([\N{U+0370}-\N{U+03FF}]+)/\\lgrande{$1}/g;
  $s =~ s/([\N{U+0590}-\N{U+05FF}]+)/\\lgrande{$1}/g;
  $s =~ s/([\N{U+16A0}-\N{U+16FF}]+)/\\asymbol{$1}/g;
  $s =~ s/([\N{U+2700}-\N{U+27BF}]+)/\\lgrande{$1}/g;
  $s =~ s/([\N{U+20A0}-\N{U+20CF}]+)/\\lgrande{$1}/g;
  $s =~ s/([\N{U+0900}-\N{U+097F}]+)/\\skt{$1}/g;
  $s =~ s/([\N{U+2600}-\N{U+26FF}]+)/\\emoji{$1}/g;
  $s =~ s/([\N{U+4E00}-\N{U+9FFF}]+)/\\cjk{$1}/g;
  $s =~ s/__(.+?)__/\\cjk{$1}/g;
  $s =~ s/____/\\underline{\\hspace{2em}}/g;
  $s =~ s/\\&ast;/*/g;
  $s =~ s/\\&lt;/</g;
  $s =~ s/\\&gt;/>/g;
  $s =~ s/\((B?CotD)\)/({\\color{red}$1})/g;
  $s =~ s/\(((ACC|JCD)PPotD)\)/({\\color{red}$1})/g;
  $s =~ s/\(TCS\)/({\\color{red}TCS})/g;
  $s =~ s/<sub>(.+?)<\/sub>/{\\textsubscript {$1}}/g;
  $s =~ s/<sup>(.+?)<\/sup>/{\\textsuperscript {$1}}/g;
  $s =~ s/<frac>(.+?)\/(.+?)<\/frac>/\$\\frac{$1}{$2}\$/g;
  my $new = '';
  my $oq;
  my @chars = split m//, $s;
  foreach my $char (@chars)
  {
    if ($char eq '"')
    {
      unless ($oq)
      {
        $char = '``';
        $oq = 1;
      }
      else
      {
        $oq = 0;
      }
    }
    $new .= $char;
  }
  $s = $new;
  $s =~ s/\\('+)/\$$1\$/g;
  $s =~ s/\\&rdquo;/"/g;
  return $s;
}

sub Git
{
  my $n = (defined $opt_number)? $opt_number : $maxShowNumber;
  my $cmd = "git commit -m 'Show $n.' NASummaries.txt";
  print BLUE "$cmd\n" if $opt_verbose;
  `$cmd` unless $opt_noop;
  $cmd = 'git push origin master';
  print BLUE "$cmd\n" if $opt_verbose;
  `$cmd` unless $opt_noop;
}

sub Upload
{
  my $cmd = 'rsync -azrlv --exclude=".DS_Store" -e ssh na/ blugs@blugs.com:blugs.com/na';
  print BLUE "$cmd\n" if $opt_verbose;
  `$cmd` unless $opt_noop;
}
