package DBIx::ObjectMapper::Engine::DBI::Driver::mysql;
use strict;
use warnings;
use Try::Tiny;
use Carp::Clan;
use base qw(DBIx::ObjectMapper::Engine::DBI::Driver);

sub init {
    my $self = shift;
    try {
        require DateTime::Format::MySQL;
        DateTime::Format::MySQL->import;
        $self->{datetime_parser} ||= 'DateTime::Format::MySQL';
    } catch {
        confess "Couldn't load DateTime::Format::MySQL: $_";
    };
}

sub last_insert_id {
    my ( $self, $dbh, $table, $column ) = @_;
    $dbh->{mysql_insertid};
}

sub get_primary_key {
    my $self = shift;
    return @{$self->_mysql_table_get_keys(@_)->{PRIMARY}};
}

sub get_table_uniq_info {
    my $self = shift;

    my @uniqs;
    my $keydata = $self->_mysql_table_get_keys(@_);
    foreach my $keyname (keys %$keydata) {
        next if $keyname eq 'PRIMARY';
        push(@uniqs, [ $keyname => $keydata->{$keyname} ]);
    }
    return \@uniqs;
}

#  mostly based on DBIx::Class::Schema::Loader::DBI::mysql
sub _mysql_table_get_keys {
    my ($self, $dbh, $table) = @_;

    if(!exists($self->{_cache}->{_mysql_keys}->{$table})) {
        my %keydata;
        my $sth = $dbh->prepare("SHOW INDEX FROM `$table`");
        $sth->execute;
        while(my $row = $sth->fetchrow_hashref) {
            next if $row->{Non_unique};
            push(@{$keydata{$row->{Key_name}}},
                [ $row->{Seq_in_index}, lc $row->{Column_name} ]
            );
        }
        foreach my $keyname (keys %keydata) {
            my @ordered_cols = map { $_->[1] } sort { $a->[0] <=> $b->[0] }
                @{$keydata{$keyname}};
            $keydata{$keyname} = \@ordered_cols;
        }
        $self->{_cache}->{_mysql_keys}->{$table} = \%keydata;
    }

    return $self->{_cache}->{_mysql_keys}->{$table};
}

sub get_table_fk_info {
    my ($self, $dbh, $table) = @_;

    my $table_def_ref = $dbh->selectrow_arrayref("SHOW CREATE TABLE `$table`")
        or croak ("Cannot get table definition for $table");
    my $table_def = $table_def_ref->[1] || '';

    my (@reldata) = ($table_def =~ /CONSTRAINT `.*` FOREIGN KEY \(`(.*)`\) REFERENCES `(.*)` \(`(.*)`\)/ig);

    my @rels;
    while (scalar @reldata > 0) {
        my $cols = shift @reldata;
        my $f_table = shift @reldata;
        my $f_cols = shift @reldata;

        my @cols   = map { s/\Q$self->{quote}\E//; lc $_ } ## no critic
            split(/\s*,\s*/, $cols);

        my @f_cols = map { s/\Q$self->{quote}\E//; lc $_ } ## no critic
            split(/\s*,\s*/, $f_cols);

        push(@rels, {
            keys  => \@cols,
            refs  => \@f_cols,
            table => $f_table
        });
    }

    return \@rels;
}

sub get_tables {
    my ( $self, $dbh ) = @_;
    my @tables = $dbh->tables(undef, $self->db_schema, undef, undef);
    s/\Q$self->{quote}\E//g for @tables;
    s/^.*\Q$self->{namesep}\E// for @tables;
    return @tables;
}

sub set_time_zone_query {
    my ( $self ) = @_;
    my $tz = $self->{time_zone};
    return "SET timezone = $tz";
}

1;