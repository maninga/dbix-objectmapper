package Data::ObjectMapper::Metadata::Table::Column::Type::Storable;
use strict;
use warnings;
use base qw(Data::ObjectMapper::Metadata::Table::Column::Type::Text);

use Storable ();
use MIME::Base64 ();

sub from_storage {
    my ( $self, $val ) = @_;
    return $val unless defined $val;
    return Storable::thaw(MIME::Base64::decode($val));
}

sub to_storage {
    my ( $self, $val ) = @_;
    return $val unless defined $val and ref($val);
    return MIME::Base64::encode(Storable::nfreeze($val));
}

1;
