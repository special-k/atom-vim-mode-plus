Grim  = require 'grim'
_ = require 'underscore-plus'
{Point, Range, Emitter, Disposable, CompositeDisposable} = require 'atom'
settings = require './settings'

Operators   = require './operators'
Prefixes    = require './prefixes'
Motions     = require './motions'
InsertMode  = require './insert-mode'
TextObjects = require './text-objects'

Scroll = require './scroll'
OperationStack = require './operation-stack'

Utils  = require './utils'

module.exports =
class VimState
  editor: null
  operationStack: null
  mode: null
  submode: null
  destroyed: false
  replaceModeListener: null
  # count: null # Used to instruct number of repeat count to each operation.

  constructor: (@editorElement, @statusBarManager, @globalVimState) ->
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @editor = @editorElement.getModel()
    @history = []
    @marks = {}
    @subscriptions.add @editor.onDidDestroy => @destroy()
    @operationStack = new OperationStack(this)
    @counter = @getCounter()

    @subscriptions.add @editor.onDidChangeSelectionRange _.debounce(=>
      return unless @editor?
      if @editor.getSelections().every((selection) -> selection.isEmpty())
        @activateNormalMode() if @isVisualMode()
      else
        @activateVisualMode('characterwise') if @isNormalMode()
    , 100)

    @subscriptions.add @editor.onDidChangeCursorPosition ({cursor}) =>
      @ensureCursorIsWithinLine(cursor)
    @subscriptions.add @editor.onDidAddCursor @ensureCursorIsWithinLine

    @editorElement.classList.add("vim-mode")
    @init()
    if settings.startInInsertMode()
      @activateInsertMode()
    else
      @activateNormalMode()

  destroy: ->
    return if @destroyed
    @destroyed = true
    @emitter.emit 'did-destroy'
    @subscriptions.dispose()
    if @editor.isAlive()
      @deactivateInsertMode()
      @editorElement.component?.setInputEnabled(true)
      @editorElement.classList.remove("vim-mode")
      @editorElement.classList.remove("normal-mode")
    @editor = null
    @editorElement = null

  # Private: Creates the plugin's bindings
  #
  # Returns nothing.
  init: ->
    @registerCommands
      'activate-normal-mode': => @activateNormalMode()
      'activate-linewise-visual-mode': => @activateVisualMode('linewise')
      'activate-characterwise-visual-mode': => @activateVisualMode('characterwise')
      'activate-blockwise-visual-mode': => @activateVisualMode('blockwise')
      'reset-normal-mode': => @resetNormalMode()
      'set-count': (e) => @counter.set(e)
      'reverse-selections': (e) => @reverseSelections(e)
      'undo': => @undo()
      'replace-mode-backspace': => @replaceModeUndo()
      'insert-mode-put': (e) => @insertRegister(@registerName(e))
      'copy-from-line-above': => InsertMode.copyCharacterFromAbove(@editor, this)
      'copy-from-line-below': => InsertMode.copyCharacterFromBelow(@editor, this)

    @registerOperationCommands
      # Motions
      'move-left': => new Motions.MoveLeft(this)
      'move-up': => new Motions.MoveUp(this)
      'move-down': => new Motions.MoveDown(this)
      'move-right': => new Motions.MoveRight(this)
      'move-to-next-word': => new Motions.MoveToNextWord(this)
      'move-to-next-whole-word': => new Motions.MoveToNextWholeWord(this)
      'move-to-end-of-word': => new Motions.MoveToEndOfWord(this)
      'move-to-end-of-whole-word': => new Motions.MoveToEndOfWholeWord(this)
      'move-to-previous-word': => new Motions.MoveToPreviousWord(this)
      'move-to-previous-whole-word': => new Motions.MoveToPreviousWholeWord(this)
      'move-to-next-paragraph': => new Motions.MoveToNextParagraph(this)
      'move-to-previous-paragraph': => new Motions.MoveToPreviousParagraph(this)
      'move-to-first-character-of-line': => new Motions.MoveToFirstCharacterOfLine(this)
      'move-to-first-character-of-line-and-down': => new Motions.MoveToFirstCharacterOfLineAndDown(this)
      'move-to-last-character-of-line': => new Motions.MoveToLastCharacterOfLine(this)
      'move-to-last-nonblank-character-of-line-and-down': => new Motions.MoveToLastNonblankCharacterOfLineAndDown(this)
      'move-to-first-character-of-line-up': => new Motions.MoveToFirstCharacterOfLineUp(this)
      'move-to-first-character-of-line-down': => new Motions.MoveToFirstCharacterOfLineDown(this)
      'move-to-start-of-file': => new Motions.MoveToStartOfFile(this)
      'move-to-line': => new Motions.MoveToAbsoluteLine(this)

      'move-to-top-of-screen': => new Motions.MoveToTopOfScreen(this)
      'move-to-bottom-of-screen': => new Motions.MoveToBottomOfScreen(this)
      'move-to-middle-of-screen': => new Motions.MoveToMiddleOfScreen(this)

      'scroll-half-screen-up': => new Motions.ScrollHalfUpKeepCursor(this)
      'scroll-full-screen-up': => new Motions.ScrollFullUpKeepCursor(this)
      'scroll-half-screen-down': => new Motions.ScrollHalfDownKeepCursor(this)
      'scroll-full-screen-down': => new Motions.ScrollFullDownKeepCursor(this)

      'repeat-search': => new Motions.RepeatSearch(this)
      'repeat-search-backwards': => new Motions.RepeatSearch(this).reversed()
      'move-to-mark': => new Motions.MoveToMark(this)
      'move-to-mark-literal': => new Motions.MoveToMark(this, false)
      'find': => new Motions.Find(this)
      'find-backwards': => new Motions.Find(this).reverse()
      'till': => new Motions.Till(this)
      'till-backwards': => new Motions.Till(this).reverse()
      'search': => new Motions.Search(this)
      'reverse-search': => new Motions.Search(this).reversed()
      'search-current-word': => new Motions.SearchCurrentWord(this)
      'bracket-matching-motion': => new Motions.BracketMatchingMotion(this)
      'reverse-search-current-word': => new Motions.SearchCurrentWord(this).reversed()

      # TextObject
      'select-inside-word': => new TextObjects.SelectInsideWord(@editor)
      'select-inside-whole-word': => new TextObjects.SelectInsideWholeWord(@editor)
      'select-inside-double-quotes': => new TextObjects.SelectInsideQuotes(@editor, '"', false)
      'select-inside-single-quotes': => new TextObjects.SelectInsideQuotes(@editor, '\'', false)
      'select-inside-back-ticks': => new TextObjects.SelectInsideQuotes(@editor, '`', false)
      'select-inside-curly-brackets': => new TextObjects.SelectInsideBrackets(@editor, '{', '}', false)
      'select-inside-angle-brackets': => new TextObjects.SelectInsideBrackets(@editor, '<', '>', false)
      'select-inside-tags': => new TextObjects.SelectInsideBrackets(@editor, '>', '<', false)
      'select-inside-square-brackets': => new TextObjects.SelectInsideBrackets(@editor, '[', ']', false)
      'select-inside-parentheses': => new TextObjects.SelectInsideBrackets(@editor, '(', ')', false)
      'select-inside-paragraph': => new TextObjects.SelectInsideParagraph(@editor, false)
      'select-a-word': => new TextObjects.SelectAWord(@editor)
      'select-a-whole-word': => new TextObjects.SelectAWholeWord(@editor)
      'select-around-double-quotes': => new TextObjects.SelectInsideQuotes(@editor, '"', true)
      'select-around-single-quotes': => new TextObjects.SelectInsideQuotes(@editor, '\'', true)
      'select-around-back-ticks': => new TextObjects.SelectInsideQuotes(@editor, '`', true)
      'select-around-curly-brackets': => new TextObjects.SelectInsideBrackets(@editor, '{', '}', true)
      'select-around-angle-brackets': => new TextObjects.SelectInsideBrackets(@editor, '<', '>', true)
      'select-around-square-brackets': => new TextObjects.SelectInsideBrackets(@editor, '[', ']', true)
      'select-around-parentheses': => new TextObjects.SelectInsideBrackets(@editor, '(', ')', true)
      'select-around-paragraph': => new TextObjects.SelectAParagraph(@editor, true)

      # [FIXME]
      'register-prefix': (e) => @registerPrefix(e)
      'move-to-beginning-of-line': (e) => @moveOrRepeat(e)
      'repeat-find': => new @globalVimState.currentFind.constructor(this, repeated: true) if @globalVimState.currentFind
      'repeat-find-reverse': => new @globalVimState.currentFind.constructor(this, repeated: true, reverse: true) if @globalVimState.currentFind


    @registerNewOperationCommands Operators, [
      'activate-insert-mode'
      'activate-replace-mode'
      'substitute'
      'substitute-line'
      'insert-after'
      'insert-after-end-of-line'
      'insert-at-beginning-of-line'
      'insert-above-with-newline'
      'insert-below-with-newline'
      'delete'
      'change'
      'change-to-last-character-of-line'
      'delete-right'
      'delete-left'
      'delete-to-last-character-of-line'
      'toggle-case'
      'upper-case'
      'lower-case'
      'toggle-case-now'
      'yank'
      'yank-line'
      'put-before',
      'put-after'
      'join'
      'indent'
      'outdent'
      'auto-indent'
      'increase'
      'decrease'
      'repeat'
      'mark'
      'replace'
    ]
    @registerNewOperationCommands Scroll, [
      'scroll-down'
      'scroll-up'
      'scroll-cursor-to-top'
      'scroll-cursor-to-middle'
      'scroll-cursor-to-bottom'
      'scroll-cursor-to-top-leave'
      'scroll-cursor-to-middle-leave'
      'scroll-cursor-to-bottom-leave'
      'scroll-cursor-to-left'
      'scroll-cursor-to-right'
      ]

  # Private: Register multiple command handlers via an {Object} that maps
  # command names to command handler functions.
  #
  # Prefixes the given command names with 'vim-mode:' to reduce redundancy in
  # the provided object.
  registerCommands: (commands) ->
    for name, fn of commands
      do (fn) =>
        @subscriptions.add atom.commands.add(@editorElement, "vim-mode:#{name}", fn)

  # Private: Register multiple Operators via an {Object} that
  # maps command names to functions that return operations to push.
  #
  # Prefixes the given command names with 'vim-mode:' to reduce redundancy in
  # the given object.
  registerOperationCommands: (operationCommands) ->
    commands = {}
    for name, fn of operationCommands
      do (fn) =>
        commands[name] = (event) => @operationStack.push(fn(event))
    @registerCommands(commands)

  # 'New' is 'new' way of registration to distinguish exisiting function.
  # By maping command name to correspoinding class.
  #  e.g.
  # join -> Join
  # scroll-down -> ScrollDown
  registerNewOperationCommands: (kind, names) ->
    commands = {}
    for name in names
      do (name) =>
        klass = _.capitalize(_.camelize(name))
        commands[name] = => new kind[klass](this)
    @registerOperationCommands(commands)

  onDidFailToCompose: (fn) ->
    @emitter.on('failed-to-compose', fn)

  onDidDestroy: (fn) ->
    @emitter.on('did-destroy', fn)

  undo: ->
    @editor.undo()
    @activateNormalMode()

  ##############################################################################
  # Register
  ##############################################################################

  # Private: Fetches the value of a given register.
  #
  # name - The name of the register to fetch.
  #
  # Returns the value of the given register or undefined if it hasn't
  # been set.
  getRegister: (name) ->
    if name is '"'
      name = settings.defaultRegister()

    switch name
      when '*', '+'
        text = atom.clipboard.read()
        type = Utils.copyType(text)
        {text, type}
      when '%'
        text = @editor.getURI()
        type = Utils.copyType(text)
        {text, type}
      when '_' # Blackhole always returns nothing
        text = ''
        type = Utils.copyType(text)
        {text, type}
      else
        @globalVimState.registers[name.toLowerCase()]

  # Private: Sets the value of a given register.
  #
  # name  - The name of the register to fetch.
  # value - The value to set the register to.
  #
  # Returns nothing.
  setRegister: (name, value) ->
    if name is '"'
      name = settings.defaultRegister()

    switch name
      when '*', '+'
        atom.clipboard.write(value.text)
      when '_'
        null
      else
        if /^[A-Z]$/.test(name)
          @appendRegister(name.toLowerCase(), value)
        else
          @globalVimState.registers[name] = value

  # Private: append a value into a given register
  # like setRegister, but appends the value
  appendRegister: (name, {type, text}) ->
    register = @globalVimState.registers[name] ?=
      type: 'character'
      text: ''

    if register.type is 'linewise' and type isnt 'linewise'
      register.text += "#{text}\n"
    else if register.type isnt 'linewise' and type is 'linewise'
      register.text += "\n#{text}"
      register.type = 'linewise'
    else
      register.text += text

  ##############################################################################
  # Mark
  ##############################################################################

  # Private: Fetches the value of a given mark.
  #
  # name - The name of the mark to fetch.
  #
  # Returns the value of the given mark or undefined if it hasn't
  # been set.
  getMark: (name) ->
    if @marks[name]
      @marks[name].getBufferRange().start
    else
      undefined

  # Private: Sets the value of a given mark.
  #
  # name  - The name of the mark to fetch.
  # pos {Point} - The value to set the mark to.
  #
  # Returns nothing.
  setMark: (name, pos) ->
    # check to make sure name is in [a-z] or is `
    if (charCode = name.charCodeAt(0)) >= 96 and charCode <= 122
      marker = @editor.markBufferRange(new Range(pos, pos), {invalidate: 'never', persistent: false})
      @marks[name] = marker

  ##############################################################################
  # Search History
  ##############################################################################

  # Public: Append a search to the search history.
  #
  # Motions.Search - The confirmed search motion to append
  #
  # Returns nothing
  pushSearchHistory: (search) -> # should be saveSearchHistory for consistency.
    @globalVimState.searchHistory.unshift search

  # Public: Get the search history item at the given index.
  #
  # index - the index of the search history item
  #
  # Returns a search motion
  getSearchHistoryItem: (index = 0) ->
    @globalVimState.searchHistory[index]

  ##############################################################################
  # Mode Switching
  ##############################################################################

  # Private: Used to enable normal mode.
  #
  # Returns nothing.
  activateNormalMode: ->
    @deactivateInsertMode()
    @deactivateVisualMode()

    @mode = 'normal'
    @submode = null

    @changeModeClass('normal-mode')

    @operationStack.clear()
    selection.clear(autoscroll: false) for selection in @editor.getSelections()
    for cursor in @editor.getCursors()
      if cursor.isAtEndOfLine() and not cursor.isAtBeginningOfLine()
        cursor.moveLeft()

    @updateStatusBar()

  # TODO: remove this method and bump the `vim-mode` service version number.
  activateCommandMode: ->
    Grim.deprecate("Use ::activateNormalMode instead")
    @activateNormalMode()

  # Private: Used to enable insert mode.
  #
  # Returns nothing.
  activateInsertMode: (subtype = null) ->
    @mode = 'insert'
    @editorElement.component.setInputEnabled(true)
    @setInsertionCheckpoint()
    @submode = subtype
    @changeModeClass('insert-mode')
    @updateStatusBar()

  activateReplaceMode: ->
    @activateInsertMode('replace')
    @replaceModeCounter = 0
    @editorElement.classList.add('replace-mode')
    @subscriptions.add @replaceModeListener = @editor.onWillInsertText @replaceModeInsertHandler
    @subscriptions.add @replaceModeUndoListener = @editor.onDidInsertText @replaceModeUndoHandler

  replaceModeInsertHandler: (event) =>
    chars = event.text?.split('') or []
    selections = @editor.getSelections()
    for char in chars
      continue if char is '\n'
      for selection in selections
        selection.delete() unless selection.cursor.isAtEndOfLine()
    return

  replaceModeUndoHandler: (event) =>
    @replaceModeCounter++

  replaceModeUndo: ->
    if @replaceModeCounter > 0
      @editor.undo()
      @editor.undo()
      @editor.moveLeft()
      @replaceModeCounter--

  setInsertionCheckpoint: ->
    @insertionCheckpoint = @editor.createCheckpoint() unless @insertionCheckpoint?

  deactivateInsertMode: ->
    return unless @mode in [null, 'insert']
    @editorElement.component.setInputEnabled(false)
    @editorElement.classList.remove('replace-mode')
    @editor.groupChangesSinceCheckpoint(@insertionCheckpoint)
    changes = getChangesSinceCheckpoint(@editor.buffer, @insertionCheckpoint)
    item = @inputOperator(@history[0])
    @insertionCheckpoint = null
    if item?
      item.confirmChanges(changes)
    for cursor in @editor.getCursors()
      cursor.moveLeft() unless cursor.isAtBeginningOfLine()
    if @replaceModeListener?
      @replaceModeListener.dispose()
      @subscriptions.remove @replaceModeListener
      @replaceModeListener = null
      @replaceModeUndoListener.dispose()
      @subscriptions.remove @replaceModeUndoListener
      @replaceModeUndoListener = null

  deactivateVisualMode: ->
    return unless @isVisualMode()
    for selection in @editor.getSelections()
      selection.cursor.moveLeft() unless (selection.isEmpty() or selection.isReversed())

  # Private: Get the input operator that needs to be told about about the
  # typed undo transaction in a recently completed operation, if there
  # is one.
  inputOperator: (item) ->
    return item unless item?
    return item if item.inputOperator?()
    return item.composedObject if item.composedObject?.inputOperator?()

  # Private: Used to enable visual mode.
  #
  # type - One of 'characterwise', 'linewise' or 'blockwise'
  #
  # Returns nothing.
  activateVisualMode: (type) ->
    # Already in 'visual', this means one of following command is
    # executed within `vim-mode.visual-mode`
    #  * activate-blockwise-visual-mode
    #  * activate-characterwise-visual-mode
    #  * activate-linewise-visual-mode
    if @isVisualMode()
      if @submode is type
        @activateNormalMode()
        return

      @submode = type
      if @submode is 'linewise'
        for selection in @editor.getSelections()
          # Keep original range as marker's property to get back
          # to characterwise.
          # Since selectLine lost original cursor column.
          originalRange = selection.getBufferRange()
          selection.marker.setProperties({originalRange})
          [start, end] = selection.getBufferRowRange()
          selection.selectLine(row) for row in [start..end]

      else if @submode in ['characterwise', 'blockwise']
        # Currently, 'blockwise' is not yet implemented.
        # So treat it as characterwise.
        # Recover original range.
        for selection in @editor.getSelections()
          {originalRange} = selection.marker.getProperties()
          if originalRange
            [startRow, endRow] = selection.getBufferRowRange()
            originalRange.start.row = startRow
            originalRange.end.row   = endRow
            selection.setBufferRange(originalRange)
    else
      @deactivateInsertMode()
      @mode = 'visual'
      @submode = type
      @changeModeClass('visual-mode')

      if @submode is 'linewise'
        @editor.selectLinesContainingCursors()
      else if @editor.getSelectedText() is ''
        @editor.selectRight()

    @updateStatusBar()

  # Private: Used to re-enable visual mode
  resetVisualMode: ->
    @activateVisualMode(@submode)

  # Private: Used to enable operator-pending mode.
  activateOperatorPendingMode: ->
    @deactivateInsertMode()
    @mode = 'operator-pending'
    @submode = null
    @changeModeClass('operator-pending-mode')

    @updateStatusBar()

  changeModeClass: (targetMode) ->
    for mode in ['normal-mode', 'insert-mode', 'visual-mode', 'operator-pending-mode']
      if mode is targetMode
        @editorElement.classList.add(mode)
      else
        @editorElement.classList.remove(mode)

  # Private: Resets the normal mode back to it's initial state.
  #
  # Returns nothing.
  resetNormalMode: ->
    @operationStack.clear()
    @editor.clearSelections()
    @activateNormalMode()

  # Private: A generic way to create a Register prefix based on the event.
  #
  # e - The event that triggered the Register prefix.
  #
  # Returns nothing.
  registerPrefix: (e) ->
    new Prefixes.Register(@registerName(e))

  # Private: Gets a register name from a keyboard event
  #
  # e - The event
  #
  # Returns the name of the register
  registerName: (e) ->
    keyboardEvent = e.originalEvent?.originalEvent ? e.originalEvent
    name = atom.keymaps.keystrokeForKeyboardEvent(keyboardEvent)
    if name.lastIndexOf('shift-', 0) is 0
      name = name.slice(6)
    name

  # Private: A create a Number prefix based on the event.
  #
  # e - The event that triggered the Number prefix.
  #
  # Returns nothing.
  getCounter: ->
    count = null
    isOperatorPending = @isOperatorPending.bind(this)
    set: (e) ->
      keyboardEvent = e.originalEvent?.originalEvent ? e.originalEvent
      num = parseInt(atom.keymaps.keystrokeForKeyboardEvent(keyboardEvent))

      # To cover scenario `10d3y` in this case we use 3, need to trash 10.
      if isOperatorPending()
        @reset()
      count ?= 0
      count = count * 10 + num

    get: ->
      count

    reset: ->
      count = null

  reverseSelections: ->
    reversed = not @editor.getLastSelection().isReversed()
    for selection in @editor.getSelections()
      selection.setBufferRange(selection.getBufferRange(), {reversed})

  # Private: Figure out whether or not we are in a repeat sequence or we just
  # want to move to the beginning of the line. If we are within a repeat
  # sequence, we pass control over to @repeatPrefix.
  #
  # e - The triggered event.
  #
  # Returns new motion or nothing.
  moveOrRepeat: (e) ->
    if @counter.get()?
      @counter.set(e)
      null
    else
      new Motions.MoveToBeginningOfLine(this)

  isOperatorPending: ->
    not @operationStack.isEmpty()

  isVisualMode: -> @mode is 'visual'
  isNormalMode: -> @mode is 'normal'
  isInsertMode: -> @mode is 'insert'
  isOperatorPendingMode: -> @mode is 'operator-pending'

  updateStatusBar: ->
    @statusBarManager.update(@mode, @submode)

  # Private: insert the contents of the register in the editor
  #
  # name - the name of the register to insert
  #
  # Returns nothing.
  insertRegister: (name) ->
    text = @getRegister(name)?.text
    @editor.insertText(text) if text?

  ensureCursorIsWithinLine: (cursor) =>
    return if @operationStack.isProcessing() or (not @isNormalMode())

    {goalColumn} = cursor
    if cursor.isAtEndOfLine() and not cursor.isAtBeginningOfLine()
      @operationStack.withLock -> # to ignore the cursor change (and recursion) caused by the next line
        cursor.moveLeft()
    cursor.goalColumn = goalColumn

# This uses private APIs and may break if TextBuffer is refactored.
# Package authors - copy and paste this code at your own risk.
getChangesSinceCheckpoint = (buffer, checkpoint) ->
  {history} = buffer

  if (index = history.getCheckpointIndex(checkpoint))?
    history.undoStack.slice(index)
  else
    []
