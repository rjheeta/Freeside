package FS::cust_pkg::Search;

use strict;
use FS::CurrentUser;
use FS::UI::Web;
use FS::cust_main;
use FS::cust_pkg;

=item search HASHREF

(Class method)

Returns a qsearch hash expression to search for parameters specified in HASHREF.
Valid parameters are

=over 4

=item agentnum

=item status

on hold, active, inactive (or one-time charge), suspended, canceled (or cancelled)

=item magic

Equivalent to "status", except that "canceled"/"cancelled" will exclude 
packages that were changed into a new package with the same pkgpart (i.e.
location or quantity changes).

=item custom

 boolean selects custom packages

=item classnum

=item pkgpart

pkgpart or arrayref or hashref of pkgparts

=item setup

arrayref of beginning and ending epoch date

=item last_bill

arrayref of beginning and ending epoch date

=item bill

arrayref of beginning and ending epoch date

=item adjourn

arrayref of beginning and ending epoch date

=item susp

arrayref of beginning and ending epoch date

=item expire

arrayref of beginning and ending epoch date

=item cancel

arrayref of beginning and ending epoch date

=item query

pkgnum or APKG_pkgnum

=item cust_fields

a value suited to passing to FS::UI::Web::cust_header

=item CurrentUser

specifies the user for agent virtualization

=item fcc_line

boolean; if true, returns only packages with more than 0 FCC phone lines.

=item state, country

Limit to packages with a service location in the specified state and country.
For FCC 477 reporting, mostly.

=item location_cust

Limit to packages whose service locations are the same as the customer's 
default service location.

=item location_nocust

Limit to packages whose service locations are not the customer's default 
service location.

=item location_census

Limit to packages whose service locations have census tracts.

=item location_nocensus

Limit to packages whose service locations do not have a census tract.

=item location_geocode

Limit to packages whose locations have geocodes.

=item location_geocode

Limit to packages whose locations do not have geocodes.

=item towernum

Limit to packages associated with a svc_broadband, associated with a sector,
associated with this towernum (or any of these, if it's an arrayref) (or NO
towernum, if it's zero). This is an extreme niche case.

=item 477part, 477rownum, date

Limit to packages included in a specific row of one of the FCC 477 reports.
'477part' is the section name (see L<FS::Report::FCC_477> methods), 'date'
is the report as-of date (completely unrelated to the package setup/bill/
other date fields), and '477rownum' is the row number of the report starting
with zero. Row numbers have no inherent meaning, so this is useful only 
for explaining a 477 report you've already run.

=back

=cut

sub search {
  my ($class, $params) = @_;
  my @where = ();

  ##
  # parse agent
  ##

  if ( $params->{'agentnum'} =~ /^(\d+)$/ and $1 ) {
    push @where,
      "cust_main.agentnum = $1";
  }

  ##
  # parse cust_status
  ##

  if ( $params->{'cust_status'} =~ /^([a-z]+)$/ ) {
    push @where, FS::cust_main->cust_status_sql . " = '$1' ";
  }

  ##
  # parse customer sales person
  ##

  if ( $params->{'cust_main_salesnum'} =~ /^(\d+)$/ ) {
    push @where, ($1 > 0) ? "cust_main.salesnum = $1"
                          : 'cust_main.salesnum IS NULL';
  }


  ##
  # parse sales person
  ##

  if ( $params->{'salesnum'} =~ /^(\d+)$/ ) {
    push @where, ($1 > 0) ? "cust_pkg.salesnum = $1"
                          : 'cust_pkg.salesnum IS NULL';
  }

  ##
  # parse custnum
  ##

  if ( $params->{'custnum'} =~ /^(\d+)$/ and $1 ) {
    push @where,
      "cust_pkg.custnum = $1";
  }

  ##
  # custbatch
  ##

  if ( $params->{'pkgbatch'} =~ /^([\w\/\-\:\.]+)$/ and $1 ) {
    push @where,
      "cust_pkg.pkgbatch = '$1'";
  }

  ##
  # parse status
  ##

  if (    $params->{'magic'}  eq 'active'
       || $params->{'status'} eq 'active' ) {

    push @where, FS::cust_pkg->active_sql();

  } elsif (    $params->{'magic'}  =~ /^not[ _]yet[ _]billed$/
            || $params->{'status'} =~ /^not[ _]yet[ _]billed$/ ) {

    push @where, FS::cust_pkg->not_yet_billed_sql();

  } elsif (    $params->{'magic'}  =~ /^(one-time charge|inactive)/
            || $params->{'status'} =~ /^(one-time charge|inactive)/ ) {

    push @where, FS::cust_pkg->inactive_sql();

  } elsif (    $params->{'magic'}  =~ /^on[ _]hold$/
            || $params->{'status'} =~ /^on[ _]hold$/ ) {

    push @where, FS::cust_pkg->on_hold_sql();


  } elsif (    $params->{'magic'}  eq 'suspended'
            || $params->{'status'} eq 'suspended'  ) {

    push @where, FS::cust_pkg->suspended_sql();

  } elsif (    $params->{'magic'}  =~ /^cancell?ed$/
            || $params->{'status'} =~ /^cancell?ed$/ ) {

    push @where, FS::cust_pkg->cancelled_sql();

  }
  
  ### special case: "magic" is used in detail links from browse/part_pkg,
  # where "cancelled" has the restriction "and not replaced with a package
  # of the same pkgpart".  Be consistent with that.
  ###

  if ( $params->{'magic'} =~ /^cancell?ed$/ ) {
    my $new_pkgpart = "SELECT pkgpart FROM cust_pkg AS cust_pkg_next ".
                      "WHERE cust_pkg_next.change_pkgnum = cust_pkg.pkgnum";
    # ...may not exist, if this was just canceled and not changed; in that
    # case give it a "new pkgpart" that never equals the old pkgpart
    push @where, "COALESCE(($new_pkgpart), 0) != cust_pkg.pkgpart";
  }

  ###
  # parse package class
  ###

  if ( exists($params->{'classnum'}) ) {

    my @classnum = ();
    if ( ref($params->{'classnum'}) ) {

      if ( ref($params->{'classnum'}) eq 'HASH' ) {
        @classnum = grep $params->{'classnum'}{$_}, keys %{ $params->{'classnum'} };
      } elsif ( ref($params->{'classnum'}) eq 'ARRAY' ) {
        @classnum = @{ $params->{'classnum'} };
      } else {
        die 'unhandled classnum ref '. $params->{'classnum'};
      }


    } elsif ( $params->{'classnum'} =~ /^(\d*)$/ && $1 ne '0' ) {
      @classnum = ( $1 );
    }

    if ( @classnum ) {

      my @c_where = ();
      my @nums = grep $_, @classnum;
      push @c_where, 'part_pkg.classnum IN ('. join(',',@nums). ')' if @nums;
      my $null = scalar( grep { $_ eq '' } @classnum );
      push @c_where, 'part_pkg.classnum IS NULL' if $null;

      if ( scalar(@c_where) == 1 ) {
        push @where, @c_where;
      } elsif ( @c_where ) {
        push @where, ' ( '. join(' OR ', @c_where). ' ) ';
      }

    }
    

  }

  ###
  # parse (customer) refnum (advertising source)
  ###

  if ( exists($params->{'refnum'}) ) {
    my @refnum;
    if (ref $params->{'refnum'}) {
      @refnum = @{ $params->{'refnum'} };
    } else {
      @refnum = ( $params->{'refnum'} );
    }
    my $in = join(',', grep /^\d+$/, @refnum);
    push @where, "cust_main.refnum IN($in)" if length $in;
  }

  ###
  # parse package report options
  ###

  my @report_option = ();
  if ( exists($params->{'report_option'}) ) {
    if ( ref($params->{'report_option'}) eq 'ARRAY' ) {
      @report_option = @{ $params->{'report_option'} };
    } elsif ( $params->{'report_option'} =~ /^([,\d]*)$/ ) {
      @report_option = split(',', $1);
    }

  }

  if (@report_option) {
    # this will result in the empty set for the dangling comma case as it should
    push @where, 
      map{ "EXISTS ( SELECT 1 FROM part_pkg_option
                       WHERE part_pkg_option.pkgpart = part_pkg.pkgpart
                       AND optionname = 'report_option_$_'
                       AND optionvalue = '1' )"
         } @report_option;
  }

  foreach my $any ( grep /^report_option_any/, keys %$params ) {

    my @report_option_any = ();
    if ( ref($params->{$any}) eq 'ARRAY' ) {
      @report_option_any = @{ $params->{$any} };
    } elsif ( $params->{$any} =~ /^([,\d]*)$/ ) {
      @report_option_any = split(',', $1);
    }

    if (@report_option_any) {
      # this will result in the empty set for the dangling comma case as it should
      push @where, ' ( '. join(' OR ',
        map{ "EXISTS ( SELECT 1 FROM part_pkg_option
                         WHERE part_pkg_option.pkgpart = part_pkg.pkgpart
                         AND optionname = 'report_option_$_'
                         AND optionvalue = '1' )"
           } @report_option_any
      ). ' ) ';
    }

  }

  ###
  # parse custom
  ###

  push @where,  "part_pkg.custom = 'Y'" if $params->{custom};

  ###
  # parse fcc_line
  ###

  push @where,  "(part_pkg.fcc_ds0s > 0 OR pkg_class.fcc_ds0s > 0)" 
                                                        if $params->{fcc_line};

  ###
  # parse censustract
  ###

  if ( exists($params->{'censustract'}) ) {
    $params->{'censustract'} =~ /^([.\d]*)$/;
    my $censustract = "cust_location.censustract = '$1'";
    $censustract .= ' OR cust_location.censustract is NULL' unless $1;
    push @where,  "( $censustract )";
  }

  ###
  # parse censustract2
  ###
  if ( exists($params->{'censustract2'})
       && $params->{'censustract2'} =~ /^(\d*)$/
     )
  {
    if ($1) {
      push @where, "cust_location.censustract LIKE '$1%'";
    } else {
      push @where,
        "( cust_location.censustract = '' OR cust_location.censustract IS NULL )";
    }
  }

  ###
  # parse country/state/zip
  ###
  for (qw(state country)) { # parsing rules are the same for these
  if ( exists($params->{$_}) 
    && uc($params->{$_}) =~ /^([A-Z]{2})$/ )
    {
      # XXX post-2.3 only--before that, state/country may be in cust_main
      push @where, "cust_location.$_ = '$1'";
    }
  }
  if ( exists($params->{zip}) ) {
    push @where, "cust_location.zip = " . dbh->quote($params->{zip});
  }

  ###
  # location_* flags
  ###
  if ( $params->{location_cust} xor $params->{location_nocust} ) {
    my $op = $params->{location_cust} ? '=' : '!=';
    push @where, "cust_location.locationnum $op cust_main.ship_locationnum";
  }
  if ( $params->{location_census} ) {
    push @where, "cust_location.censustract IS NOT NULL",
                 "cust_location.censusyear  =  '2020'  ";
  } elsif ( $params->{location_nocensus} ) {
    push @where, "(    cust_location.censustract IS NULL    ".
                 "  OR cust_location.censusyear  != '2020' )";
  }
  if ( $params->{location_geocode} xor $params->{location_nogeocode} ) {
    my $op = $params->{location_geocode} ? "IS NOT NULL" : "IS NULL";
    push @where, "cust_location.geocode $op";
  }

  ###
  # parse part_pkg
  ###

  if ( ref($params->{'pkgpart'}) ) {

    my @pkgpart = ();
    if ( ref($params->{'pkgpart'}) eq 'HASH' ) {
      @pkgpart = grep $params->{'pkgpart'}{$_}, keys %{ $params->{'pkgpart'} };
    } elsif ( ref($params->{'pkgpart'}) eq 'ARRAY' ) {
      @pkgpart = @{ $params->{'pkgpart'} };
    } else {
      die 'unhandled pkgpart ref '. $params->{'pkgpart'};
    }

    @pkgpart = grep /^(\d+)$/, @pkgpart;

    push @where, 'pkgpart IN ('. join(',', @pkgpart). ')' if scalar(@pkgpart);

  } elsif ( $params->{'pkgpart'} =~ /^(\d+)$/ ) {
    push @where, "pkgpart = $1";
  } 

  ###
  # parse dates
  ###

  my $orderby = '';

  #false laziness w/report_cust_pkg.html
  my %disable = (
    'all'             => {},
    'one-time charge' => { 'last_bill'=>1, 'bill'=>1, 'adjourn'=>1, 'susp'=>1, 'expire'=>1, 'cancel'=>1, },
    'active'          => { 'susp'=>1, 'cancel'=>1 },
    'suspended'       => { 'cancel' => 1 },
    'cancelled'       => {},
    ''                => {},
  );

  if ( exists($params->{'active'} ) ) {

    # This overrides all the other date-related fields, and includes packages
    # that were active at some time during the interval.  It excludes:
    # - packages that were set up after the end of the interval
    # - packages that were canceled before the start of the interval
    # - packages that were suspended before the start of the interval
    #   and are still suspended now
    my($beginning, $ending) = @{$params->{'active'}};
    push @where,
      "cust_pkg.setup IS NOT NULL",
      "cust_pkg.setup <= $ending",
      "(cust_pkg.cancel IS NULL OR cust_pkg.cancel >= $beginning )",
      "(cust_pkg.susp   IS NULL OR cust_pkg.susp   >= $beginning )",
      "NOT (".FS::cust_pkg->onetime_sql . ")";

  } else {

    my $exclude_change_from = 0;
    my $exclude_change_to = 0;

    foreach my $field (qw( setup last_bill bill adjourn susp expire contract_end change_date cancel )) {

      if ( $params->{$field.'_null'} ) {

        push @where, "cust_pkg.$field IS NULL";
             # this should surely be obsoleted by now: OR cust_pkg.$field == 0 )

      } else {

        next unless exists($params->{$field});

        my($beginning, $ending) = @{$params->{$field}};

        next if $beginning == 0 && $ending == 4294967295;

        push @where,
          "cust_pkg.$field IS NOT NULL",
          "cust_pkg.$field >= $beginning",
          "cust_pkg.$field <= $ending";

        $orderby ||= "ORDER BY cust_pkg.$field";

        if ( $field eq 'setup' ) {
          $exclude_change_from = 1;
        } elsif ( $field eq 'cancel' ) {
          $exclude_change_to = 1;
        } elsif ( $field eq 'change_date' ) {
          # if we are given setup and change_date ranges, and the setup date
          # falls in _both_ ranges, then include the package whether it was 
          # a change or not
          $exclude_change_from = 0;
        }

      }

    }

    if ($exclude_change_from) {
      push @where, "cust_pkg.change_pkgnum IS NULL";
    }
    if ($exclude_change_to) {
      # a join might be more efficient here
      push @where, "NOT EXISTS(
        SELECT 1 FROM cust_pkg AS changed_to_pkg
        WHERE cust_pkg.pkgnum = changed_to_pkg.change_pkgnum
      )";
    }

  }

  $orderby ||= 'ORDER BY bill';

  ###
  # parse magic, legacy, etc.
  ###

  if ( $params->{'magic'} &&
       $params->{'magic'} =~ /^(active|inactive|suspended|cancell?ed)$/
  ) {

    $orderby = 'ORDER BY pkgnum';

    if ( $params->{'pkgpart'} =~ /^(\d+)$/ ) {
      push @where, "pkgpart = $1";
    }

  } elsif ( $params->{'query'} eq 'pkgnum' ) {

    $orderby = 'ORDER BY pkgnum';

  } elsif ( $params->{'query'} eq 'APKG_pkgnum' ) {

    $orderby = 'ORDER BY pkgnum';

    push @where, '0 < (
      SELECT count(*) FROM pkg_svc
       WHERE pkg_svc.pkgpart =  cust_pkg.pkgpart
         AND pkg_svc.quantity > ( SELECT count(*) FROM cust_svc
                                   WHERE cust_svc.pkgnum  = cust_pkg.pkgnum
                                     AND cust_svc.svcpart = pkg_svc.svcpart
                                )
    )';
  
  }

  ##
  # parse the extremely weird 'towernum' param
  ##

  if ($params->{towernum}) {
    my $towernum = $params->{towernum};
    $towernum = [ $towernum ] if !ref($towernum);
    my $in = join(',', grep /^\d+$/, @$towernum);
    if (length $in) {
      # inefficient, but this is an obscure feature
      eval "use FS::Report::Table";
      FS::Report::Table->_init_tower_pkg_cache; # probably does nothing
      push @where, "EXISTS(
      SELECT 1 FROM tower_pkg_cache
      WHERE tower_pkg_cache.pkgnum = cust_pkg.pkgnum
        AND tower_pkg_cache.towernum IN ($in)
      )"
    }
  }

  ##
  # parse the 477 report drill-down options
  ##

  if ($params->{'477part'} =~ /^([a-z]+)$/) {
    my $section = $1;
    my ($date, $rownum, $agentnum);
    if ($params->{'date'} =~ /^(\d+)$/) {
      $date = $1;
    }
    if ($params->{'477rownum'} =~ /^(\d+)$/) {
      $rownum = $1;
    }
    if ($params->{'agentnum'} =~ /^(\d+)$/) {
      $agentnum = $1;
    }
    if ($date and defined($rownum)) {
      my $report = FS::Report::FCC_477->report($section,
        'date'      => $date,
        'agentnum'  => $agentnum,
        'detail'    => 1
      );
      my $pkgnums = $report->{detail}->[$rownum]
        or die "row $rownum is past the end of the report";
        # '0' so that if there are no pkgnums (empty string) it will create
        # a valid query that returns nothing
      warn "PKGNUMS:\n$pkgnums\n\n"; # XXX debug

      # and this overrides everything
      @where = ( "cust_pkg.pkgnum IN($pkgnums)" );
    } # else we're missing some params, ignore the whole business
  }

  ##
  # setup queries, links, subs, etc. for the search
  ##

  # here is the agent virtualization
  if ($params->{CurrentUser}) {
    my $access_user =
      qsearchs('access_user', { username => $params->{CurrentUser} });

    if ($access_user) {
      push @where, $access_user->agentnums_sql('table'=>'cust_main');
    } else {
      push @where, "1=0";
    }
  } else {
    push @where, $FS::CurrentUser::CurrentUser->agentnums_sql('table'=>'cust_main');
  }

  push @where,  "cust_pkg_reason.reasonnum = '".$params->{reasonnum}."'" if $params->{reasonnum};

  my $extra_sql = scalar(@where) ? ' WHERE '. join(' AND ', @where) : '';

  my $addl_from = 'LEFT JOIN part_pkg  USING ( pkgpart  ) '.
                  'LEFT JOIN pkg_class ON ( part_pkg.classnum = pkg_class.classnum ) '.
                  'LEFT JOIN cust_location USING ( locationnum ) '.
                  FS::UI::Web::join_cust_main('cust_pkg', 'cust_pkg');

  if ($params->{reasonnum}) {
    $addl_from .= 'LEFT JOIN cust_pkg_reason ON (cust_pkg_reason.pkgnum = cust_pkg.pkgnum) ';
  }

  my $select;
  my $count_query;
  if ( $params->{'select_zip5'} ) {
    my $zip = 'cust_location.zip';

    $select = "DISTINCT substr($zip,1,5) as zip";
    $orderby = "ORDER BY substr($zip,1,5)";
    $count_query = "SELECT COUNT( DISTINCT substr($zip,1,5) )";
  } else {
    $select = join(', ',
                         'cust_pkg.*',
                         ( map "part_pkg.$_", qw( pkg freq ) ),
                         'pkg_class.classname',
                         'cust_main.custnum AS cust_main_custnum',
                         FS::UI::Web::cust_sql_fields(
                           $params->{'cust_fields'}
                         ),
                  );
    $count_query = 'SELECT COUNT(*)';
  }

  $count_query .= " FROM cust_pkg $addl_from $extra_sql";

  my $sql_query = {
    'table'       => 'cust_pkg',
    'hashref'     => {},
    'select'      => $select,
    'extra_sql'   => $extra_sql,
    'order_by'    => $orderby,
    'addl_from'   => $addl_from,
    'count_query' => $count_query,
  };

}

1;

