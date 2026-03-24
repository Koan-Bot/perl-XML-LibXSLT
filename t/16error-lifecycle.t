use strict;
use warnings;

# Regression tests for error handler lifecycle.
#
# Issue #8: When libxml2 calls error/debug handlers during GC (e.g. in
# libxml2 2.14+), stale function pointers to freed SVs cause SEGV.
# These tests verify that:
#   1. Errors from one operation don't leak into the next
#   2. Sequential failed+successful operations work correctly
#   3. The error handler is properly scoped per-operation

use Test::More tests => 14;
use XML::LibXSLT;
use XML::LibXML;

my $parser = XML::LibXML->new();
my $xslt   = XML::LibXSLT->new();

# A valid stylesheet
my $good_xsl = <<'XSL';
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:template match="/">
    <out><xsl:value-of select="/doc/text()"/></out>
  </xsl:template>
</xsl:stylesheet>
XSL

# An invalid stylesheet (bad element name)
my $bad_xsl = <<'XSL';
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:templat match="/">
    <out/>
  </xsl:templat>
</xsl:stylesheet>
XSL

# A stylesheet that triggers a transform-time error (undefined variable)
my $error_xsl = <<'XSL';
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:template match="/">
    <out><xsl:value-of select="$undefined_var"/></out>
  </xsl:template>
</xsl:stylesheet>
XSL

my $doc = $parser->parse_string('<doc>hello</doc>');

# ---- Test 1: failed parse_stylesheet followed by successful one ----
{
    my $bad_doc = $parser->parse_string($bad_xsl);
    eval { $xslt->parse_stylesheet($bad_doc) };
    # TEST
    ok($@, 'bad stylesheet parse fails');

    my $good_doc = $parser->parse_string($good_xsl);
    my $stylesheet;
    eval { $stylesheet = $xslt->parse_stylesheet($good_doc) };
    # TEST
    ok(!$@, 'good stylesheet parse succeeds after failed one');
    # TEST
    ok($stylesheet, 'stylesheet object created');

    my $result = $stylesheet->transform($doc);
    # TEST
    like($stylesheet->output_string($result), qr/hello/,
         'transform produces correct output after prior parse failure');
}

# ---- Test 2: failed transform followed by successful one ----
{
    my $error_doc = $parser->parse_string($error_xsl);
    my $error_ss  = $xslt->parse_stylesheet($error_doc);
    # TEST
    ok($error_ss, 'error-triggering stylesheet parses OK');

    eval { $error_ss->transform($doc) };
    # TEST
    ok($@, 'transform with undefined variable fails');

    # Now do a successful transform with a different stylesheet
    my $good_doc = $parser->parse_string($good_xsl);
    my $good_ss  = $xslt->parse_stylesheet($good_doc);
    my $result   = $good_ss->transform($doc);
    # TEST
    like($good_ss->output_string($result), qr/hello/,
         'successful transform after prior transform failure');
}

# ---- Test 3: error isolation between sequential transforms ----
{
    my $good_doc = $parser->parse_string($good_xsl);
    my $good_ss  = $xslt->parse_stylesheet($good_doc);

    my $warn_text = '';
    local $SIG{__WARN__} = sub { $warn_text .= $_[0] };

    # First: successful transform
    my $r1 = $good_ss->transform($doc);
    # TEST
    like($good_ss->output_string($r1), qr/hello/,
         'first transform OK');

    # Second: also successful — errors should not leak
    my $r2 = $good_ss->transform($parser->parse_string('<doc>world</doc>'));
    # TEST
    like($good_ss->output_string($r2), qr/world/,
         'second transform OK');

    # TEST
    is($warn_text, '', 'no stale warnings leaked between transforms');
}

# ---- Test 4: rapid parse/transform cycle (stress the handler lifecycle) ----
{
    my $all_ok = 1;
    for my $i (1..20) {
        my $xsl_doc = $parser->parse_string($good_xsl);
        my $ss      = $xslt->parse_stylesheet($xsl_doc);
        my $input   = $parser->parse_string("<doc>iter$i</doc>");
        my $result  = $ss->transform($input);
        my $out     = $ss->output_string($result);
        unless ($out =~ /iter$i/) {
            $all_ok = 0;
            last;
        }
    }
    # TEST
    ok($all_ok, '20 rapid parse/transform cycles all produce correct output');
}

# ---- Test 5: interleaved error and success ----
{
    my $bad_doc  = $parser->parse_string($bad_xsl);
    my $good_doc = $parser->parse_string($good_xsl);

    for my $round (1..3) {
        eval { $xslt->parse_stylesheet($parser->parse_string($bad_xsl)) };
        # errors expected, just discard
    }

    my $ss = $xslt->parse_stylesheet($parser->parse_string($good_xsl));
    my $result = $ss->transform($doc);
    # TEST
    like($ss->output_string($result), qr/hello/,
         'transform works after 3 consecutive parse failures');
}

# ---- Test 6: transform_file error followed by transform success ----
{
    my $good_doc = $parser->parse_string($good_xsl);
    my $ss       = $xslt->parse_stylesheet($good_doc);

    eval { $ss->transform_file('/nonexistent/path/to/file.xml') };
    # TEST
    ok($@, 'transform_file with missing file fails');

    my $result = $ss->transform($doc);
    # TEST
    like($ss->output_string($result), qr/hello/,
         'transform succeeds after transform_file failure');
}
