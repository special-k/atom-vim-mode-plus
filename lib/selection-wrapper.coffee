{Range, Point, Disposable} = require 'atom'
{
  translatePointAndClip
  getRangeByTranslatePointAndClip
  getEndOfLineForBufferRow
  getBufferRangeForRowRange
  limitNumber
  isLinewiseRange
  assertWithException
} = require './utils'
BlockwiseSelection = null

propertyStore = new Map

class SelectionWrapper
  constructor: (@selection) ->
  hasProperties: -> propertyStore.has(@selection)
  getProperties: -> propertyStore.get(@selection)
  setProperties: (prop) -> propertyStore.set(@selection, prop)
  clearProperties: -> propertyStore.delete(@selection)
  setWiseProperty: (value) -> @getProperties().wise = value

  setBufferRangeSafely: (range, options) ->
    if range
      @setBufferRange(range, options)

  getBufferRange: ->
    @selection.getBufferRange()

  getBufferPositionFor: (which, {from}={}) ->
    for _from in from ? ['selection']
      switch _from
        when 'property'
          continue unless @hasProperties()

          properties = @getProperties()
          return switch which
            when 'start' then (if @selection.isReversed() then properties.head else properties.tail)
            when 'end' then (if @selection.isReversed() then properties.tail else properties.head)
            when 'head' then properties.head
            when 'tail' then properties.tail

        when 'selection'
          return switch which
            when 'start' then @selection.getBufferRange().start
            when 'end' then @selection.getBufferRange().end
            when 'head' then @selection.getHeadBufferPosition()
            when 'tail' then @selection.getTailBufferPosition()
    null

  setBufferPositionTo: (which) ->
    @selection.cursor.setBufferPosition(@getBufferPositionFor(which))

  setReversedState: (isReversed) ->
    return if @selection.isReversed() is isReversed

    if @hasProperties()
      {head, tail, wise} = @getProperties()
      @setProperties(head: tail, tail: head, wise: wise)

    @setBufferRange @getBufferRange(),
      autoscroll: true
      reversed: isReversed
      keepGoalColumn: false

  getRows: ->
    [startRow, endRow] = @selection.getBufferRowRange()
    [startRow..endRow]

  getRowCount: ->
    @getRows().length

  getRowFor: (where) ->
    [startRow, endRow] = @selection.getBufferRowRange()
    if @selection.isReversed()
      [headRow, tailRow] = [startRow, endRow]
    else
      [headRow, tailRow] = [endRow, startRow]

    switch where
      when 'start' then startRow
      when 'end' then endRow
      when 'head' then headRow
      when 'tail' then tailRow

  getTailBufferRange: ->
    {editor} = @selection
    tailPoint = @selection.getTailBufferPosition()
    if @selection.isReversed()
      point = translatePointAndClip(editor, tailPoint, 'backward')
      new Range(point, tailPoint)
    else
      point = translatePointAndClip(editor, tailPoint, 'forward')
      new Range(tailPoint, point)

  saveProperties: (isNormalized) ->
    head = @selection.getHeadBufferPosition()
    tail = @selection.getTailBufferPosition()
    if @selection.isEmpty() or isNormalized
      properties = {head, tail}
    else
      # We selectRight-ed in visual-mode, this translation de-effect select-right-effect
      # So that we can activate-visual-mode without special translation after restoreing properties.
      end = translatePointAndClip(@selection.editor, @getBufferRange().end, 'backward')
      if @selection.isReversed()
        properties = {head: head, tail: end}
      else
        properties = {head: end, tail: tail}
    @setProperties(properties)

  fixPropertyRowToRowRange: ->
    assertWithException(@hasProperties(), "trying to fixPropertyRowToRowRange on properties-less selection")
    {head, tail} = @getProperties()
    if @selection.isReversed()
      [head.row, tail.row] = @selection.getBufferRowRange()
    else
      [tail.row, head.row] = @selection.getBufferRowRange()

  # NOTE:
  # 'wise' must be 'characterwise' or 'linewise'
  # Use this for normalized(non-select-right-ed) selection.
  applyWise: (wise) ->
    assertWithException(@hasProperties(), "trying to applyWise #{wise} on properties-less selection")
    switch wise
      when 'characterwise'
        @translateSelectionEndAndClip('forward') # equivalent to core selection.selectRight but keep goalColumn
      when 'linewise'
        # Even if end.column is 0, expand over that end.row( don't care selection.getRowRange() )
        {start, end} = @getBufferRange()
        @setBufferRange(getBufferRangeForRowRange(@selection.editor, [start.row, end.row]))
      when 'blockwise'
        BlockwiseSelection ?= require './blockwise-selection'
        new BlockwiseSelection(@selection)

    @setWiseProperty(wise)

  selectByProperties: ({head, tail}, options) ->
    # No problem if head is greater than tail, Range constructor swap start/end.
    @setBufferRange([tail, head], options)
    @setReversedState(head.isLessThan(tail))

  # set selections bufferRange with default option {autoscroll: false, preserveFolds: true}
  setBufferRange: (range, options={}) ->
    if options.keepGoalColumn ? true
      goalColumn = @selection.cursor.goalColumn
    delete options.keepGoalColumn
    options.autoscroll ?= false
    options.preserveFolds ?= true
    @selection.setBufferRange(range, options)
    @selection.cursor.goalColumn = goalColumn if goalColumn?

  isSingleRow: ->
    [startRow, endRow] = @selection.getBufferRowRange()
    startRow is endRow

  isLinewiseRange: ->
    isLinewiseRange(@getBufferRange())

  detectWise: ->
    if @isLinewiseRange()
      'linewise'
    else
      'characterwise'

  # direction must be one of ['forward', 'backward']
  translateSelectionEndAndClip: (direction) ->
    newRange = getRangeByTranslatePointAndClip(@selection.editor, @getBufferRange(), "end", direction)
    @setBufferRange(newRange)

  # Return selection extent to replay blockwise selection on `.` repeating.
  getBlockwiseSelectionExtent: ->
    head = @selection.getHeadBufferPosition()
    tail = @selection.getTailBufferPosition()
    new Point(head.row - tail.row, head.column - tail.column)

  # What's the normalize?
  # Normalization is restore selection range from property.
  # As a result it range became range where end of selection moved to left.
  # This end-move-to-left de-efect of end-mode-to-right effect( this is visual-mode orientation )
  normalize: ->
    # empty selection IS already 'normalized'
    return if @selection.isEmpty()
    assertWithException(@hasProperties(), "attempted to normalize but no properties to restore")
    @selectByProperties(@getProperties())

swrap = (selection) ->
  new SelectionWrapper(selection)

swrap.getSelections = (editor) ->
  editor.getSelections(editor).map(swrap)

swrap.setReversedState = (editor, reversed) ->
  $selection.setReversedState(reversed) for $selection in @getSelections(editor)

swrap.detectWise = (editor) ->
  if @getSelections(editor).every(($selection) -> $selection.isLinewiseRange())
    'linewise'
  else
    'characterwise'

swrap.clearProperties = (editor) ->
  $selection.clearProperties() for $selection in @getSelections(editor)

swrap.dumpProperties = (editor) ->
  {inspect} = require 'util'
  for $selection in @getSelections(editor) when $selection.hasProperties()
    console.log inspect($selection.getProperties())

swrap.hasProperties = (editor) ->
  @getSelections(editor).every ($selection) -> $selection.hasProperties()

swrap.normalize = (editor) ->
  $selection.normalize() for $selection in @getSelections(editor)

swrap.applyWise = (editor, wise) ->
  $selection.applyWise(wise) for $selection in @getSelections(editor)

# Return function to restore
# Used in vmp-move-selected-text
swrap.switchToLinewise = (editor) ->
  for $selection in @getSelections(editor)
    $selection.saveProperties()
    $selection.applyWise('linewise')
  new Disposable ->
    for $selection in @getSelections(editor)
      $selection.normalize()
      $selection.applyWise('characterwise')

swrap.getPropertyStore = ->
  propertyStore

module.exports = swrap
