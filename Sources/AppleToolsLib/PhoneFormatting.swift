import Foundation
import PhoneNumberKit

/// Canonical phone-number formatting for all apple-tools JSON output.
///
/// Every tool emits phone numbers that are *known to be phone numbers* in
/// **E.164** — e.g. `+15551234567`. This is the phone analogue of
/// ``DateFormatting``: the same concept (a phone number) was previously
/// rendered differently per tool/source — Contacts returned the raw
/// `CNContact` string (`(555) 123-4567`, `+1 555-123-4567`, `555.123.4567` all
/// for the same number), Messages surfaced handles in whatever shape the chat
/// DB stored. An agent reading across Contacts + Messages couldn't treat "the
/// same number" as equal. Routing all phone output through one formatter is the
/// structural fix (issue #12, mirroring #11 / v0.3.0).
///
/// Parsing is delegated to PhoneNumberKit (libphonenumber port) for ITU-grade
/// validation — see ADR-0001. Hard type validation is left ON (the default), so
/// non-numbers are *rejected* rather than coerced: emails, marketing
/// short codes, and unparseable junk return `nil` from ``e164(_:)`` and pass
/// through ``normalized(_:)`` unchanged. A value is never silently corrupted.
///
/// Output only. Accepting varied phone formats as *input* / search arguments is
/// explicitly out of scope (issue #12 non-goal).
public enum PhoneFormatting {
    /// ISO 3166-1 region used to interpret a bare national number that lacks a
    /// `+` country code (e.g. `5551234567`). Defaults to the machine's region.
    ///
    /// Like ``DateFormatting/outputTimeZone``, this is settable once at startup:
    /// `AppleToolsLib` runs both as a CLI on the user's own Mac *and* inside a
    /// probe whose machine isn't necessarily where the user is, so the system
    /// region can be wrong for a remote consumer. A consumer that knows the
    /// user's actual region can override it:
    ///
    /// ```swift
    /// PhoneFormatting.defaultRegion = "GB"
    /// ```
    ///
    /// Numbers that already carry a `+` country code are unaffected by this —
    /// the region only matters for expanding bare national numbers.
    public static var defaultRegion: String = Locale.current.region?.identifier ?? "US"

    /// Shared parser. A `PhoneNumberUtility` parses and holds metadata in memory
    /// for its lifetime — relatively expensive to allocate — so we keep exactly
    /// one. apple-tools runs single-threaded per invocation.
    private static let utility = PhoneNumberUtility()

    /// Canonicalize a string to E.164 if (and only if) it is confidently a valid
    /// phone number, else return `nil`.
    ///
    /// Returns `nil` for emails, marketing short codes, and anything that fails
    /// libphonenumber's hard validation — callers should leave those values
    /// untouched. A bare national number (no `+`) is interpreted using
    /// ``defaultRegion``.
    public static func e164(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Emails are valid Messages handles but not phone numbers; never coerce.
        guard !trimmed.contains("@") else { return nil }

        guard let number = try? utility.parse(trimmed, withRegion: defaultRegion) else {
            return nil
        }
        return utility.format(number, toType: .e164)
    }

    /// Canonicalize a string to E.164 if it is a valid phone number, otherwise
    /// return it unchanged. Use this for fields that *are* always phone numbers
    /// (e.g. a Contacts phone value) where the canonical form replaces the raw
    /// one in place — an unparseable value is preserved rather than dropped.
    public static func normalized(_ raw: String) -> String {
        e164(raw) ?? raw
    }
}
