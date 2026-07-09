import '../json.dart';

/// One parametric-EQ band (`/api/eq/opra` shape). [q] for biquad types,
/// [slope] (dB/oct) only for low/high_pass.
class EqBand {
  const EqBand({
    required this.type,
    required this.frequency,
    this.gainDb = 0,
    this.q,
    this.slope,
  });

  final String type;
  final double frequency;
  final double gainDb;
  final double? q;
  final double? slope;

  factory EqBand.fromJson(Map<String, dynamic> j) => EqBand(
        type: asString(j['type']) ?? '',
        frequency: asDouble(j['frequency']) ?? 0,
        gainDb: asDouble(j['gainDb']) ?? 0,
        q: asDouble(j['q']),
        slope: asDouble(j['slope']),
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'frequency': frequency,
        'gainDb': gainDb,
        if (q != null) 'q': q,
        if (slope != null) 'slope': slope,
      };
}

/// A parametric EQ: preamp [gainDb] plus [bands]. [author] is set on OPRA
/// profiles; [name] on app-side selections/custom presets.
class EqProfile {
  const EqProfile({
    this.name,
    this.author,
    this.details,
    this.gainDb = 0,
    this.bands = const [],
  });

  final String? name;
  final String? author;
  final String? details;
  final double gainDb;
  final List<EqBand> bands;

  factory EqProfile.fromJson(Map<String, dynamic> j) => EqProfile(
        name: asString(j['name']),
        author: asString(j['author']),
        details: asString(j['details']),
        gainDb: asDouble(j['gainDb']) ?? 0,
        bands: [
          for (final b in (j['bands'] as List? ?? const []))
            if (b is Map<String, dynamic>) EqBand.fromJson(b),
        ],
      );

  Map<String, dynamic> toJson() => {
        if (name != null) 'name': name,
        if (author != null) 'author': author,
        if (details != null) 'details': details,
        'gainDb': gainDb,
        'bands': [for (final b in bands) b.toJson()],
      };
}

/// `/api/eq/opra` — one headphone with its community EQs.
class OpraProduct {
  const OpraProduct({
    required this.vendor,
    required this.product,
    this.eqs = const [],
  });

  final String vendor;
  final String product;
  final List<EqProfile> eqs;

  factory OpraProduct.fromJson(Map<String, dynamic> j) => OpraProduct(
        vendor: asString(j['vendor']) ?? '',
        product: asString(j['product']) ?? '',
        eqs: [
          for (final e in (j['eqs'] as List? ?? const []))
            if (e is Map<String, dynamic>) EqProfile.fromJson(e),
        ],
      );
}
