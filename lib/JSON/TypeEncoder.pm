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
    die "error string eval: $@, src: $src" if $@;
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
    for my $i (keys @keys) {
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

    sprintf(q!(_validate_hash_ref(!.$obj_src.q!) && '{%s}')!, join "", @src);
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
    sprintf(q!'[' . (do {my $src; for (@{_validate_array_ref(%s)}) { $src .= (%s) . ',' }; substr($src,0,-1) }) . ']'!, $obj_src, $src);
}

sub _json_src_str {
    my ($self, $value_src) = @_;
    qq!'"' . _escape(_validate_str($value_src)) . '"'!
}

sub _json_src_num {
    my ($self, $value_src) = @_;
    qq!_validate_num($value_src)!
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

sub _validate_hash_ref {
    ref $_[0] eq 'HASH' or die "not hash ref";
    $_[0];
}

sub _validate_array_ref {
    ref $_[0] eq 'ARRAY' or die "not array ref";
    $_[0];
}

sub _validate_num {
    use warnings FATAL => qw/numeric/;
    0+$_[0];
}

sub _validate_str {
    use overload;
    (!ref $_[0] || overload::OverloadedStringify($_[0])) or die "not string";
    $_[0];
}

{
    my %ESCAPE = (
        "\n" => '\n',
        "\r" => '\r',
        "\t" => '\t',
        "\f" => '\f',
        "\b" => '\b',
        "\"" => '\"',
        "\\" => '\\\\',
        "\'" => '\\\'',
    );

    sub _escape {
        for ($_[0]) {
            s/([\x22\x5c\n\r\t\f\b])/$ESCAPE{$1}/g;
            s/([\x00-\x08\x0b\x0e-\x1f])/'\\u00' . unpack('H2', $1)/eg;
        }
        $_[0];
    }
}

1;
__END__

=encoding utf-8

=head1 NAME

JSON::TypeEncoder - serialize JSON using type information

=head1 SYNOPSIS

    use JSON::TypeEncoder;
    use Types::Standard -types;

    my $type = Dict[a => Str, b => Int, c => Bool];

    my $jsont = JSON::TypeEncoder->new;
    my $encode = $jsont->encoder($type);

    $encode->({ a => 'foo', b => 30, c => !!1 });
    # => {"a":"foo","b":30,"c":true}

=head1 DESCRIPTION

JSON::TypeEncoder serialize Perl data structures to JSON using type information.
This module goal is to be B<correct> and B<fast>.

=head2 FEATURES

=head3 Correct

This module encodes according to the specified type information.
For example, it encodes as following:

    use JSON::TypeEncoder;
    use Types::Standard -types;

    my $jsont = JSON::TypeEncoder->new;

    my $s = $jsont->encoder(Dict[a => Str]);
    $s->({a => 123}); # => {"a":"123"}

    my $i = $jsont->encoder(Dict[a => Int]);
    $i->({a => 123}); # => {"a":123}

    my $b = $jsont->encoder(Dict[a => Bool]);
    $b->({a => !!0}); # => {"a":false}

This will prevent unintended encoding.

=head3 Fast

Encoding performance is improved by string eval using type information.
You can get speed comparable to JSON::XS. The results of a simple benchmark is as following.

First comes a comparison using a very short single-line JSON string (also available at http://dist.schmorp.de/misc/json/short.json).

    {"method": "handleMessage", "params": ["user1", "we were just talking"], "id": null, "array":[1,11,234,-5,1e5,1e7, 1,  0]}

It shows the number of encodes per second. Higher is better:

    #                       Rate JSON::PP JSON::XS w/ Types JSON::TypeEncoder JSON::XS
    # JSON::PP           39739/s       --              -83%              -90%     -95%
    # JSON::XS w/ Types 234056/s     489%                --              -42%     -72%
    # JSON::TypeEncoder 405736/s     921%               73%                --     -51%
    # JSON::XS          825118/s    1976%              253%              103%       --

Using a longer test string (roughly 18KB, generated from Yahoo! Locals search API (http://dist.schmorp.de/misc/json/long.json).

    #                      Rate          JSON::PP          JSON::XS JSON::TypeEncoder
    # JSON::PP            984/s                --              -96%              -97%
    # JSON::XS          26946/s             2639%                --              -13%
    # JSON::TypeEncoder 30919/s             3043%               15%                --

=head3 Pure Perl

This module is written by pure Perl. So you can easily install it.

=head2 B<NOT> FEATURES

This module NOT supports decode JSON to Perl data structures.
You should use other modules like JSON::XS to decode.

=head2 TYPE SPECIFICATION

L<Types::Standard> is used for type specification.
The basic types are as follows, you can specify the type of JSON by this combination.

=head3 Basic Types

=over

=item C<< Str >>

Subtype of C<< Str >> encodes always to string.

    my $encode = $jsont->encoder(Str);
    $encode->(123) # => "123"

=item C<< Num >>

Subtype of C<< Num >> encodes always to number.

    my $encode = $jsont->encoder(Num);
    $encode->(123) # => 123

=item C<< Bool >>

Subtype of C<< Bool >> encodes always to boolean.

    my $encode = $jsont->encoder(Bool);
    $encode->(123) # => true

=item C<< Dict[...] >>

Subtype of C<< Dict[...] >> encodes always to map.

    my $encode = $jsont->encoder(Dict[a => Int]);
    $encode->({ a => 123 });   # => {"a":123}
    $encode->({ a => '123' }); # => {"a":123}

=item C<< Tuple[...] >>

Subtype of C<< Tuple[A, B] >> encodes always to list of type A and B.

    my $encode = $jsont->encoder(Tuple[Int, Str]);
    $encode->([123, 456]); # => [123,"456"]

=item C<< ArrayRef[`a] >>

Subtype of C<< ArrayRef[A] >> encodes always to list of all elements type A.

    my $encode = $jsont->encoder(ArrayRef[Bool]);
    $encode->([1,0,undef,!!0,\0]); # => [true,false,false,false,true]

=item C<< Maybe >>

C<< Maybe >> encodes to undef if value is undef.

    my $encode = $jsont->encoder(Maybe[Str]);
    $encode->('hello'); # => "hello"
    $encode->(undef); # => null

=item C<< Optional[`a] >>

C<< Dict[name => Str, id => Optional[Int]] >> allows C<< { name => "Bob" } >>
but not C<< { name => "Bob", id => "BOB" } >>.

    my $encode = $jsont->encoder(Dict[a => Optional[Str]]);
    $encode->({a => 'foo'}); # => {"a":"foo"}
    $encode->({}); # => {}

=back

=head3 More Example

    use Types::Standard -types;
    use JSON::TypeEncoder;

    my $type = ArrayRef[
        Dict[
            name => Str,
            fg => Bool,
            foo => Optional[Str],
            bar => Maybe[Num]
        ]
    ];

    my $encode = JSON::TypeEncoder->new->encoder($type);
    $encode->(
        [
            { name => 'a', fg => !!1, foo => '1', bar => '10' },
            { name => 'b', fg => !!0,             bar => '11' },
            { name => 'c', fg => !!1, foo => '2', bar => undef },
            { name => 'd', fg => !!0,             bar => undef },
        ]
    );

    # =>
    # [
    #   {"bar":10,"fg":true,"foo":"1","name":"a"},
    #   {"bar":11,"fg":false,"name":"b"},
    #   {"bar":null,"fg":true,"foo":"2","name":"c"},
    #   {"bar":null,"fg":false,"name":"d"}
    # ]

=head1 SEE ALSO

L<JSON::XS>

L<JSON::Types>

L<Types::Standard>

=head1 LICENSE

Copyright (C) kfly8.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

kfly8 E<lt>kfly@cpan.orgE<gt>

=head1 CONTRIBUTORS

=over

=item karupanerura

=back

=cut

