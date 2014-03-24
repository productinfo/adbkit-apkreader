# Heavily inspired by https://github.com/xiaxiaocao/apk-parser

class BinaryXmlParser
  ChunkType =
    NULL: 0x0000
    STRING_POOL: 0x0001
    TABLE: 0x0002
    XML: 0x0003
    XML_FIRST_CHUNK: 0x0100
    XML_START_NAMESPACE: 0x0100
    XML_END_NAMESPACE: 0x0101
    XML_START_ELEMENT: 0x0102
    XML_END_ELEMENT: 0x0103
    XML_CDATA: 0x0104
    XML_LAST_CHUNK: 0x017f
    XML_RESOURCE_MAP: 0x0180
    TABLE_PACKAGE: 0x0200
    TABLE_TYPE: 0x0201
    TABLE_TYPE_SPEC: 0x0202

  StringFlags =
    SORTED: 1 << 0
    UTF8: 1 << 8

  # Taken from android.util.TypedValue
  TypedValue =
    COMPLEX_MANTISSA_MASK: 0x00ffffff
    COMPLEX_MANTISSA_SHIFT: 0x00000008
    COMPLEX_RADIX_0p23: 0x00000003
    COMPLEX_RADIX_16p7: 0x00000001
    COMPLEX_RADIX_23p0: 0x00000000
    COMPLEX_RADIX_8p15: 0x00000002
    COMPLEX_RADIX_MASK: 0x00000003
    COMPLEX_RADIX_SHIFT: 0x00000004
    COMPLEX_UNIT_DIP: 0x00000001
    COMPLEX_UNIT_FRACTION: 0x00000000
    COMPLEX_UNIT_FRACTION_PARENT: 0x00000001
    COMPLEX_UNIT_IN: 0x00000004
    COMPLEX_UNIT_MASK: 0x0000000f
    COMPLEX_UNIT_MM: 0x00000005
    COMPLEX_UNIT_PT: 0x00000003
    COMPLEX_UNIT_PX: 0x00000000
    COMPLEX_UNIT_SHIFT: 0x00000000
    COMPLEX_UNIT_SP: 0x00000002
    DENSITY_DEFAULT: 0x00000000
    DENSITY_NONE: 0x0000ffff
    TYPE_ATTRIBUTE: 0x00000002
    TYPE_DIMENSION: 0x00000005
    TYPE_FIRST_COLOR_INT: 0x0000001c
    TYPE_FIRST_INT: 0x00000010
    TYPE_FLOAT: 0x00000004
    TYPE_FRACTION: 0x00000006
    TYPE_INT_BOOLEAN: 0x00000012
    TYPE_INT_COLOR_ARGB4: 0x0000001e
    TYPE_INT_COLOR_ARGB8: 0x0000001c
    TYPE_INT_COLOR_RGB4: 0x0000001f
    TYPE_INT_COLOR_RGB8: 0x0000001d
    TYPE_INT_DEC: 0x00000010
    TYPE_INT_HEX: 0x00000011
    TYPE_LAST_COLOR_INT: 0x0000001f
    TYPE_LAST_INT: 0x0000001f
    TYPE_NULL: 0x00000000
    TYPE_REFERENCE: 0x00000001
    TYPE_STRING: 0x00000003

  constructor: (@buffer) ->
    @cursor = 0
    @strings = []
    @resources = []
    @document = null
    @parent = null
    @stack = []

  readU8: ->
    val = @buffer[@cursor]
    @cursor += 1
    return val

  readU16: ->
    val = @buffer.readUInt16LE @cursor
    @cursor += 2
    return val

  readS32: ->
    val = @buffer.readInt32LE @cursor
    @cursor += 4
    return val

  readU32: ->
    val = @buffer.readUInt32LE @cursor
    @cursor += 4
    return val

  readLength8: ->
    len = this.readU8()
    if len & 0x80
      len = (len & 0x7f) << 7
      len += this.readU8()
    return len

  readLength16: ->
    len = this.readU16()
    if len & 0x8000
      len = (len & 0x7fff) << 15
      len += this.readU16()
    return len

  readDimension: ->
    dimension =
      value: null
      unit: null
      rawUnit: null

    value = this.readU32()
    unit = dimension.value & 0xff

    dimension.value = value >> 8
    dimension.rawUnit = unit

    switch unit
      when TypedValue.COMPLEX_UNIT_MM
        dimension.unit = 'mm'
      when TypedValue.COMPLEX_UNIT_PX
        dimension.unit = 'px'
      when TypedValue.COMPLEX_UNIT_DIP
        dimension.unit = 'dp'
      when TypedValue.COMPLEX_UNIT_SP
        dimension.unit = 'sp'
      when TypedValue.COMPLEX_UNIT_PT
        dimension.unit = 'pt'
      when TypedValue.COMPLEX_UNIT_IN
        dimension.unit = 'in'

    return dimension

  readFraction: ->
    fraction =
      value: null
      type: null
      rawType: null

    value = this.readU32()
    type = value & 0xf

    fraction.value = this.convertIntToFloat value >> 4
    fraction.rawType = type

    switch type
      when TypedValue.COMPLEX_UNIT_FRACTION
        fraction.type = '%'
      when TypedValue.COMPLEX_UNIT_FRACTION_PARENT
        fraction.type = '%p'

    return fraction

  readHex24: ->
    (this.readU32() & 0xffffff).toString 16

  readHex32: ->
    this.readU32().toString 16

  convertIntToFloat: (int) ->
    buf = new ArrayBuffer 4
    new Int32Array(buf)[0] = buf
    return new Float32Array(buf)[0]

  readString: (encoding) ->
    switch encoding
      when 'utf-8'
        stringLength = this.readLength8 encoding
        byteLength = this.readLength8 encoding
        value = @buffer.toString encoding, @cursor, @cursor += byteLength
        @cursor += 2 # Skip trailing short zero
        return value
      when 'ucs2'
        stringLength = this.readLength16 encoding
        byteLength = stringLength * 2
        value = @buffer.toString encoding, @cursor, @cursor += byteLength
        @cursor += 2 # Skip trailing short zero
        return value
      else
        throw new Error "Unsupported encoding '#{encoding}'"

  readChunkHeader: ->
    chunkType: this.readU16()
    headerSize: this.readU16()
    chunkSize: this.readU32()

  readStringPool: (header) ->
    header.stringCount = this.readU32()
    header.styleCount = this.readU32()
    header.flags = this.readU32()
    header.stringsStart = this.readU32()
    header.stylesStart = this.readU32()

    if header.chunkType isnt ChunkType.STRING_POOL
      throw new Error 'Invalid string pool header'

    anchor = @cursor

    offsets = []
    offsets.push this.readU32() for [0...header.stringCount]

    #sorted = stringPoolHeader.flags & StringFlags.SORTED
    encoding =
      if header.flags & StringFlags.UTF8
        'utf-8'
      else
        'ucs2'

    @cursor = anchor + header.stringsStart - header.headerSize
    @strings.push this.readString encoding for [0...header.stringCount]

    # Skip styles
    @cursor = anchor + header.chunkSize - header.headerSize

  readResourceMap: (header) ->
    count = Math.floor (header.chunkSize - header.headerSize) / 4
    @resources.push this.readU32() for [0...count]

  readXmlNamespaceStart: (header) ->
    line = this.readU32()
    commentRef = this.readU32()
    prefixRef = this.readS32()
    uriRef = this.readS32()

    # @namespace.prefix = @strings[prefixRef] if prefixRef > 0
    # @namespace.uri = @strings[uriRef] if uriRef > 0

  readXmlNamespaceEnd: (header) ->
    line = this.readU32()
    commentRef = this.readU32()
    prefixRef = this.readS32()
    uriRef = this.readS32()

    # @namespace.prefix = @strings[prefixRef] if prefixRef > 0
    # @namespace.uri = @strings[uriRef] if uriRef > 0

  readXmlElementStart: (header) ->
    node =
      namespace: null
      name: null
      attributes: []
      children: []

    line = this.readU32()
    commentRef = this.readU32()
    nsRef = this.readS32()
    nameRef = this.readS32()

    node.namespace = @strings[nsRef] if nsRef > 0
    node.name = @strings[nameRef]

    attrStart = this.readU16()
    attrSize = this.readU16()
    attrCount = this.readU16()
    idIndex = this.readU16()
    classIndex = this.readU16()
    styleIndex = this.readU16()

    node.attributes.push this.readXmlAttribute() for [0...attrCount]

    if @document
      @parent.children.push node
      @parent = node
    else
      @document = @parent = node

    @stack.push node

    return node

  readXmlAttribute: ->
    attr =
      namespace: null
      name: null
      rawValue: null
      value: null

    nsRef = this.readS32()
    nameRef = this.readS32()
    valueRef = this.readS32()
    size = this.readU16()
    zero = this.readU8()
    dataType = this.readU8()

    attr.namespace = @strings[nsRef] if nsRef > 0
    attr.name = @strings[nameRef]
    attr.rawValue = @strings[valueRef]
    attr.dataType = dataType

    switch dataType
      when TypedValue.TYPE_INT_DEC, TypedValue.TYPE_INT_HEX
        attr.value = this.readU32()
      when TypedValue.TYPE_STRING
        ref = this.readS32()
        attr.value = @strings[ref] if ref > 0
      when TypedValue.TYPE_REFERENCE
        id = this.readU32()
        attr.value = "res:#{id}"
      when TypedValue.TYPE_INT_BOOLEAN
        attr.value = this.readS32() isnt 0
      when TypedValue.TYPE_NULL
        attr.value = null
      when TypedValue.TYPE_INT_COLOR_RGB8, TypedValue.TYPE_INT_COLOR_RGB4
        attr.value = this.readHex24()
      when TypedValue.TYPE_INT_COLOR_ARGB8, TypedValue.TYPE_INT_COLOR_ARGB4
        attr.value = this.readHex32()
      when TypedValue.TYPE_DIMENSION
        attr.value = this.readDimension()
      when TypedValue.TYPE_FRACTION
        attr.value = this.readFraction()
      else
        attr.value = this.readU32()

    return attr

  readXmlElementEnd: (header) ->
    node =
      namespace: null
      name: null
      attributes: []

    line = this.readU32()
    commentRef = this.readU32()
    nsRef = this.readS32()
    nameRef = this.readS32()

    node.namespace = @strings[nsRef] if nsRef > 0
    node.name = @strings[nameRef]

    @stack.pop()
    @parent = @stack[@stack.length - 1]

    return node

  readNull: (header) ->
    @cursor += header.chunkSize - header.headerSize

  parse: ->
    xmlHeader = this.readChunkHeader()
    if xmlHeader.chunkType isnt ChunkType.XML
      throw new Error 'Invalid XML header'

    this.readStringPool this.readChunkHeader()

    resMapHeader = this.readChunkHeader()
    if resMapHeader.chunkType is ChunkType.XML_RESOURCE_MAP
      this.readResourceMap resMapHeader
      this.readXmlNamespaceStart this.readChunkHeader()
    else
      this.readXmlNamespaceStart resMapHeader

    while @cursor < @buffer.length
      header = this.readChunkHeader()
      switch header.chunkType
        when ChunkType.XML_START_NAMESPACE
          this.readXmlNamespaceStart header
          #throw new Error 'Multiple namespaces'
        when ChunkType.XML_END_NAMESPACE
          this.readXmlNamespaceEnd header
        when ChunkType.XML_START_ELEMENT
          this.readXmlElementStart header
        when ChunkType.XML_END_ELEMENT
          this.readXmlElementEnd header
        when ChunkType.XML_CDATA
          this.readXmlCData header
        when ChunkType.NULL
          this.readNull header
        else
          throw new Error "Unsupported chunk type '#{header.chunkType}'"

    return @document

module.exports = BinaryXmlParser
