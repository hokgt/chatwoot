# frozen_string_literal: true

require 'uri'
require 'resolv'
require 'ipaddr'

# Validation + normalization for the admin-supplied ERPNext host, plus a
# network-level SSRF guard used by every ERPNext request.
#
# Rules (see the ERPNext Settings requirements):
#   * The host must be origin-only: scheme://host[:port]. Any path (other than a
#     bare "/"), query, or fragment is rejected, as are embedded credentials
#     (https://user:pass@host) — downstream code appends the ERPNext API paths.
#   * HTTPS is required for real hosts; plain HTTP is permitted only for
#     explicit localhost/loopback development hosts.
#   * A trailing slash is normalized away so downstream URL building stays clean.
#
# The module owns no state; every method is pure.
module Wijaya::Batteries::ErpLeadSidebar::HostValidator
  module_function

  # Canonical stored form: trimmed, without a trailing slash.
  def normalize(raw)
    raw.to_s.strip.chomp('/')
  end

  # Returns a human-readable error fragment (e.g. "must use HTTPS") when the host
  # is invalid, or nil when it is acceptable. Fragments are safe to surface (they
  # never echo the value back).
  def error_for(raw)
    uri = parse(normalize(raw))
    return 'is not a valid URL' if uri.nil? || uri.host.blank?
    return 'must not include embedded credentials' if uri.userinfo.present?
    return 'must be an origin only (no path, query, or fragment)' unless origin_only?(uri)
    return 'must use HTTPS' unless scheme_allowed?(uri)

    nil
  end

  # True when the URI carries only scheme://host[:port]. normalize already strips
  # a trailing slash, so an acceptable path is empty or a bare "/".
  def origin_only?(uri)
    (uri.path.blank? || uri.path == '/') && uri.query.nil? && uri.fragment.nil?
  end

  def valid?(raw)
    error_for(raw).nil?
  end

  def parse(value)
    uri = URI.parse(value)
    return nil unless uri.is_a?(URI::HTTP)

    uri
  rescue URI::InvalidURIError
    nil
  end

  def scheme_allowed?(uri)
    return true if uri.scheme == 'https'

    uri.scheme == 'http' && local_host?(uri.host)
  end

  # SSRF guard for the connection test. Explicit local/dev hosts are allowed as-is;
  # any other host must resolve exclusively to public IP addresses (blocks DNS
  # rebinding to loopback/link-local/private ranges).
  def safe_remote_uri?(uri)
    return false if uri.nil? || uri.host.blank?
    return true if local_host?(uri.host)

    ips = resolve(uri.host)
    ips.any? && ips.all? { |ip| public_ip?(ip) }
  end

  def local_host?(host)
    normalized = host.to_s.downcase
    return true if normalized == 'localhost' || normalized.end_with?('.localhost')

    safe_ipaddr(normalized)&.loopback? || false
  end

  def resolve(host)
    Resolv.getaddresses(host)
  rescue StandardError
    []
  end

  def public_ip?(ip)
    addr = safe_ipaddr(ip)
    return false if addr.nil?

    !(addr.loopback? || addr.private? || addr.link_local?)
  end

  def safe_ipaddr(value)
    IPAddr.new(value.to_s)
  rescue IPAddr::InvalidAddressError
    nil
  end
end
