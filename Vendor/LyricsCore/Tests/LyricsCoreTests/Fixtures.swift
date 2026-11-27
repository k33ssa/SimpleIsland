import Foundation
@testable import LyricsCore

/// Короткие синтетические фикстуры (тексты придуманы для тестов, реальных песен здесь нет).
enum Fixtures {
    static let src = LyricsSource(provider: .local)

    /// Пословный Apple-подобный TTML: два вокалиста, секции, фон, слоги, переводы, транслитерация, авторы.
    static let ttmlWord = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="en"><head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"><ttm:name type="full">Second Singer</ttm:name></ttm:agent><ttm:agent type="group" xml:id="v1000"/><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal" leadingSilence="0.120"><translations><translation type="subtitle" xml:lang="ru"><text for="L1">Привет, мир</text><text for="L2">Тихий <span ttm:role="x-bg">эхо</span></text></translation></translations><transliterations><transliteration xml:lang="ja-Latn"><text for="L1">haro wārudo</text></transliteration></transliterations><songwriters><songwriter>Alice A</songwriter><songwriter>Bob B</songwriter></songwriters></iTunesMetadata></metadata></head><body dur="3:36.120"><div begin="1.152" end="9.000" itunes:songPart="Verse"><p begin="1.152" end="4.000" itunes:key="L1" ttm:agent="v1"><span begin="1.152" end="1.600">Hel</span><span begin="1.600" end="2.000">lo</span> <span begin="2.100" end="3.000">world</span></p><p begin="4.500" end="9.000" itunes:key="L2" ttm:agent="v2"><span begin="4.500" end="5.000">Soft</span> <span begin="5.000" end="6.000">night</span> <span ttm:role="x-bg"><span begin="6.200" end="6.600">(echo</span> <span begin="6.600" end="7.000">echo)</span></span></p></div><div begin="10:05.250" end="1:00:01.500" itunes:songPart="Chorus" ttm:agent="v1000"><p begin="10:05.250" end="1:00:01.500" itunes:key="L3"><span begin="10:05.250" end="10:07.000">Sing</span><span begin="10:07.000" end="1:00:01.500">it</span></p></div></body></tt>
    """

    static let ttmlLine = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Line" xml:lang="ru"><head><metadata><ttm:agent type="person" xml:id="v1"/><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations/></iTunesMetadata></metadata></head><body dur="00:03:18.550"><div begin="00:00:44.460" end="00:00:50.000" itunes:songPart="Verse"><p begin="00:00:44.460" end="00:00:47.000" itunes:key="L1" ttm:agent="v1">Первая строка</p><p begin="00:00:47.500s" end="50s" itunes:key="L2" ttm:agent="v1">Вторая &amp; строка</p></div></body></tt>
    """

    /// Файл в стиле AMLL TTML DB: kebab song-part, пустой xmlns, amll:meta, inline-переводы.
    static let ttmlAMLL = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:amll="http://www.example.com/ns/amll"><head><metadata xmlns=""><ttm:agent type="person" xml:id="v1"/><amll:meta key="musicName" value="Test Song"/><amll:meta key="artists" value="Test Artist"/><amll:meta key="isrc" value="XX-AAA-00-00001"/><amll:meta key="appleMusicId" value="111"/></metadata></head><body dur="01:00.000"><div xmlns="" begin="00:01.000" end="00:05.000" itunes:song-part="Intro"><p begin="00:01.000" end="00:05.000" ttm:agent="v1" itunes:key="L1"><span begin="00:01.000" end="00:02.000">One</span> <span begin="00:02.000" end="00:03.000">two</span><span ttm:role="x-translation" xml:lang="ru">раз два</span><span ttm:role="x-roman" xml:lang="ja-Latn">wan tsū</span></p></div></body></tt>
    """

    static let lrc = """
    [ti:Test Song]
    [ar:Test Artist]
    [offset:500]
    [00:01.00]First line
    [00:05.50][00:15.50]Repeated line
    [00:10.000]
    [00:20.25]Last line
    """

    static let enhancedLRC = """
    [00:01.00]<00:01.00>Hel<00:01.40>lo <00:02.00>world <00:03.00>
    [00:04.00]v2: <00:04.00>Second <00:04.50>line
    [bg: <00:04.60>(echo)<00:05.00>]
    [00:06.00]Plain tail
    """

    static let yrc = """
    [0,45](0,45,0) 作词 : Writer One
    [45,45](45,45,0) 作曲 : Writer Two
    {"t":0,"c":[{"tx":"meta"}]}
    [1000,3000](1000,500,0)Hello (1500,500,0)wor(2000,500,0)ld(2500,100,0)! (2700,300,0)(oh (3000,400,0)yeah)
    [5000,2000](5000,400,0)Next (5400,600,0)line(6000,0,0), (6000,500,0)end
    """

    static let qrcEncryptedHex = "5E5798FF5AAC15F7B30099145B53BBD6D224C8E15A97DF853C0CFC2746FE28113AB247DCF344AC43856462DA5392FBF0EFABBCE139FB9230EC4BE4FA3EB0B41735A8C342C9BB4BA97CBA273C0CBED2BC093141D10312BA99751030C95FC547B69AE2778E3B6D391CAAE8F1C0AE5471D5E36A2D7F63DBD42D24EE0CF8C9BD2E650A1BFD53CFD6C27426675599E47C3E4655A4D8E8BC2D1B1E3DA7C3FC923362C06F8D5DC256FDECABF85F39983F2EC903D0BFD5166AC8A877F3643ABE18048B7834875CA2744DFE52017DF406EFCA9079516BCD0A2BFB86520A67A408892F699A84A38B362E7AAE1E930EACE23262C3230989E21F904CBAB709CBE7C9AEC3F4B2147A12A261654B3199B089D49A0C6125E00FE427120E23B0898AAA047707452B1C84B4ADBB4C4AABEB0273937D9285AFE5A98EEE19D83B7F763B6AE96D4722FEEAAB54B769ECAFDFAA53696A142B771F"

    static let qrcPlain = """
    [ti:Plain QRC]
    [ar:Someone]
    [0,100]Plain QRC - Someone(0,100)
    [2000,1000]One (2000,300)two(2300,400)
    """
}
