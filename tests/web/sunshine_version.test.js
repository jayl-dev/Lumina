import { describe, expect, it } from 'vitest'

import SunshineVersion from '../../src_assets/common/assets/web/sunshine_version.js'

describe('SunshineVersion', () => {
  it('parses release metadata', () => {
    const version = new SunshineVersion({
      name: 'Sunshine release',
      tag_name: 'v2026.9.16',
    })

    expect(version.release).toBeDefined()
    expect(version.version).toBe('v2026.9.16')
    expect(version.versionName).toBe('Sunshine release')
    expect(version.versionTag).toBe('v2026.9.16')
    expect(version.versionParts).toEqual([2026, 9, 16])
    expect(version.versionMajor).toBe(2026)
    expect(version.versionMinor).toBe(9)
    expect(version.versionPatch).toBe(16)
  })

  it('parses Lumina development build versions', () => {
    const version = new SunshineVersion(null, '0.0.0-1a2b3c4-dirty')

    expect(version.versionParts).toEqual([0, 0, 0])
    expect(new SunshineVersion(null, '0.0.1').isGreater(version)).toBe(true)
  })

  it('parses a version string without release metadata', () => {
    const version = new SunshineVersion(null, '1.2.3')

    expect(version.release).toBeNull()
    expect(version.versionParts).toEqual([1, 2, 3])
    expect(version.versionName).toBeNull()
    expect(version.versionTag).toBeNull()
  })

  it('requires either release metadata or a version string', () => {
    expect(() => new SunshineVersion()).toThrow('Either release or version must be provided')
  })

  it('compares version objects and strings', () => {
    const version = new SunshineVersion(null, '2.0.0')

    expect(version.isGreater('1.9.9')).toBe(true)
    expect(version.isGreater(new SunshineVersion(null, '2.0.0'))).toBe(false)
    expect(version.isGreater('3.0.0')).toBe(false)
  })

  it('handles absent and invalid comparison values', () => {
    const version = new SunshineVersion(null, '2.0.0')
    const unparsedVersion = new SunshineVersion(null, 'placeholder')
    unparsedVersion.versionParts = null

    expect(version.parseVersion(null)).toBeNull()
    expect(unparsedVersion.isGreater('1.0.0')).toBe(false)
    expect(() => version.isGreater(2)).toThrow(TypeError)
  })
})
