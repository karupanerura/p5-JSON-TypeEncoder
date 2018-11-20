package JSON::TypeEncoder;
use 5.012002;
use strict;
use warnings;

use Types::Standard -types;

our $VERSION = "0.01";

sub new {
    my $class = shift;
    bless { }, $class;
}

sub encoder {
    my ($self, $type) = @_;
    my $src = sprintf('sub {
        my $obj = shift;
        return %s
    }', $self->_json_src('$obj', $type));

    my $code = eval $src; ## no critic
    die "src: $src,\n error: $@" if $@;
    return $code;
}

sub _json_src {
    my ($self, $obj_src, $type) = @_;

    my $maybe;
    if (_is_subtype($type, Maybe)) {
        $type = $type->parameters->[0];
        $maybe = !!1;
    }

    my $src = _is_subtype($type, Dict)     ? $self->_json_src_dict($obj_src, $type)
            : _is_subtype($type, Tuple)    ? $self->_json_src_tuple($obj_src, $type)
            : _is_subtype($type, ArrayRef) ? $self->_json_src_arrayref($obj_src, $type)
            : _is_subtype($type, Bool)     ? $self->_json_src_bool($obj_src)
            : _is_subtype($type, Num)      ? $self->_json_src_num($obj_src)
            : _is_subtype($type, Str)      ? $self->_json_src_str($obj_src)
            : die "cannot parse type: $type";

    if ($maybe) {
        $src = qq!defined($obj_src) ? $src : 'null'!
    }

    return $src;
}

sub _json_src_dict {
    my ($self, $obj_src, $type) = @_;
    my @src;
    my %types = @{$type->parameters};
    my @keys = sort keys %types;
    for (my $i = 0; $i < @keys; $i++) {
        my $key      = $keys[$i];
        my $stype    = $types{$key};
        my $sobj_src = "${obj_src}->{$key}";

        my $optional;
        if (_is_subtype($stype, Optional)) {
            $stype = $stype->parameters->[0];
            $optional = !!1;
        }

        my $value_src = $self->_json_src($sobj_src, $stype);
        my $comma     = $i == 0 ? '' : ',';
        my $src       = qq!$comma"$key":' . ($value_src) . '!;

        if ($optional) {
            $src = qq!' . (exists($sobj_src) ? '$src' : '') . '!
        }

        push @src => $src;
    }

    sprintf(q!'{%s}'!, join "", @src);
}

sub _json_src_tuple {
    my ($self, $obj_src, $type) = @_;
    my @src;
    my @types = @{$type->parameters};
    for my $i (0 .. $#types) {
        my $src = $self->_json_src("${obj_src}->[$i]", $types[$i]);
        $src = qq!' . ($src) . '!;
        push @src => $src;
    }
    sprintf(q!'[%s]'!, join ",", @src);
}

sub _json_src_arrayref {
    my ($self, $obj_src, $type) = @_;
    my @src;
    my $stype = $type->parameters->[0];
    my $src = $self->_json_src('$_', $stype);
    sprintf(q!'[' . (do {my $src; for (@{%s}) { $src .= (%s) . ',' }; substr($src,0,-1) }) . ']'!, $obj_src, $src);
}

sub _json_src_str {
    my ($self, $value_src) = @_;
    qq!'"' . $value_src . '"'!
}

sub _json_src_num {
    my ($self, $value_src) = @_;
    qq!$value_src+0!
}

sub _json_src_bool {
    my ($self, $value_src) = @_;
    qq[$value_src ? 'true' : 'false']
}

sub _is_subtype {
    my ($type, $other) = @_;
    return unless $type;
    $type->name eq $other->name || _is_subtype($type->parent, $other)
}

1;
__END__

=encoding utf-8

=head1 NAME

JSON::TypeEncoder - It's new $module

=head1 SYNOPSIS

    use JSON::TypeEncoder;
    use Types::Standard -types;

    my $type = Dict[name => Str, age => Int];

    my $json = JSON::TypeEncoder->new;
    my $code = $json->encoder($type);

    $code->({ name => 'Perl', age => 30 });
    # => {"age":30,"name":"Perl"}

=head1 DESCRIPTION

JSON::TypeEncoder is ...

=head1 LICENSE

Copyright (C) kfly8.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

kfly8 E<lt>kfly@cpan.orgE<gt>

=cut

