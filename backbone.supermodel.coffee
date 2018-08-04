_ = require('underscore')
_triggerNestedChanges = (path) ->
  m = path.length - 1
  while m >= 0
    # splits the path into 2 different array
    p = path.slice(0, m)
    # the target path of the events
    q = path.slice(m)
    # an array of the remaining paths which will be used to form events
    if q.length == 1
      # this case has been handled by the normal set
      m--
      continue
    # identifies the target
    p = p.join('.')
    target = this
    if p.length > 0
      target = @get(p)
    # based on the remaining paths, form an array of all possible events
    # ['a', 'b', 'c'] results in 3 possible events a, a.b, a.b.c
    tmp = _.first(q)
    rest = _.rest(q)
    paths = [ tmp ]
    n = 0
    while n < rest.length
      tmp = [
        tmp
        rest[n]
      ].join('.')
      paths.push tmp
      n++
    l = 0
    while l < paths.length
      _p = paths[l]
      trigger = target.trigger
      if trigger and _.isFunction(trigger)
        trigger.call target, 'change:' + _p, target, target.get(_p)
      l++
    m--
  return

processKeyPath = (keyPath) ->
  if _.isString(keyPath)
    keyPath = keyPath.split('.')
  keyPath

# http://stackoverflow.com/a/16190716/386378

getObjectValue = (obj, path, def) ->
  path = processKeyPath(path)
  len = path.length
  i = 0
  while i < len
    if !obj or typeof obj != 'object'
      return def
    obj = obj[path[i]]
    i++
  if obj == undefined
    return def
  obj

# based on the concept of // http://stackoverflow.com/a/5484764/386378
# not recursively walk through the keyPath of obj
# when reaching the end call doThing
# and pass the last obj and last key

walkObject = (obj, keyPath, doThing) ->
  keyPath = processKeyPath(keyPath)
  lastKeyIndex = keyPath.length - 1
  i = 0
  while i < lastKeyIndex
    key = keyPath[i]
    if !(key of obj)
      obj[key] = {}
    obj = obj[key]
    ++i
  doThing obj, keyPath[lastKeyIndex]
  return

setObjectValue = (obj, keyPath, value) ->
  walkObject obj, keyPath, (destination, lastKey) ->
    destination[lastKey] = value
    return
  return

deleteObjectKey = (obj, keyPath) ->
  walkObject obj, keyPath, (destination, lastKey) ->
    delete destination[lastKey]
    return
  return

hasObjectKey = (obj, keyPath) ->
  hasKey = false
  walkObject obj, keyPath, (destination, lastKey) ->
    hasKey = _.has(destination, lastKey)
    return
  hasKey

# recursively walk through a Backbone.Model model
# using keyPath
# when reaching the end, call doThing
# and pass the last model and last key

walkNestedAttributes = (model, keyPath, doThing) ->
  keyPath = processKeyPath(keyPath)
  first = _.first(keyPath)
  nestedModel = model.get(first)
  if nestedModel instanceof Backbone.Model
    walkNestedAttributes nestedModel, _.rest(keyPath), doThing
  doThing model, keyPath
  return

getRelation = (obj, attr, value) ->
  relation = undefined
  if attr
    relations = _.result(obj, 'relations')
    relation = relations[attr]
  if value and !relation
    relation = Backbone.Model
  # catch all the weird stuff
  if relation == undefined
    relation = Backbone.Model
  relation

setupBackref = (obj, instance, options) ->
  name = _.result(obj, 'name')
  # respect the attribute with the same name in relation
  if name and !instance[name]
    instance[name] = obj
  instance

# a simple object is an object that does not come from "new"

isSimpleObject = (value) ->
  value.constructor == Object

SuperModel = Backbone.Model.extend(
  relations: {}
  unsafeAttributes: []
  name: null
  _valueForCollection: (value) ->
    if _.isArray(value)
      if value.length >= 1
        return _.isObject(value[0])
      return true
    false
  _nestedSet: (path, value, options) ->
    path = path.split('.')
    lastKeyIndex = path.length - 1
    obj = this
    previousObj = null
    previousKey = null
    i = 0
    while i < lastKeyIndex
      key = path[i]
      check = obj.attributes[key]
      if !check
        # initiate the relationship here
        #var relation = Backbone.Model;
        relation = getRelation(obj, key, value)
        instance = new relation
        obj.attributes[key] = setupBackref(obj, instance, options)
      obj = obj.attributes[key]
      ++i
    finalPath = path[lastKeyIndex]
    if !_.isArray(value) and _.isObject(value) and isSimpleObject(value)
      # special case when the object value is empty, just set it to an empty model
      if _.size(value) == 0
        obj.attributes[finalPath] = new Backbone.Model
      else
        for j of value
          newPath = finalPath + '.' + j
          # let _nestedSet do its things
          obj._nestedSet newPath, value[j], options
    else
      if @_valueForCollection(value)
        # here we need to initiate the collection manually
        _relation = getRelation(obj, finalPath, value)
        if _relation.prototype instanceof Backbone.Model
          # if we dont have the Collection relation for this, use custom Collection
          # because "value" should be used with a Collection
          _relation = Collection
        collection = new _relation(value)
        collection = setupBackref(obj, collection, options)
        obj.attributes[finalPath] = collection
      else
        # prevent duplicated events due to "set"
        if path.length == 1
          obj.attributes[finalPath] = value
        else
          obj.set finalPath, value, _.extend({
            skipNested: true
            forceChange: true
          }, options)
    if !options.silent
      _triggerNestedChanges.call this, path
    return
  _setChanging: ->
    @_previousAttributes = @toJSON()
    @changed = {}
    return
  _triggerChanges: (changes, options, changeValue) ->
    if changes.length
      @_pending = true
    i = 0
    l = changes.length
    while i < l
      if !changeValue
        changeValue = @get(changes[i])
      # should only handle single attribute change event here
      # change events for nested attributes should be handled by
      # _triggerNestedChanges
      if changes[i].split('.').length == 1
        @trigger 'change:' + changes[i], this, changeValue, options
      i++
    return
  _setChange: (attr, val, options) ->
    currentValue = @get(attr)
    attr = attr.split('.')
    if !_.isEqual(currentValue, val) or options.forceChange
      setObjectValue @changed, attr, val
      true
    else
      deleteObjectKey @changed, attr
      false
  set: (key, val, options) ->
    attr = undefined
    attrs = undefined
    unset = undefined
    changes = undefined
    silent = undefined
    changing = undefined
    prev = undefined
    current = undefined
    skipNested = undefined
    if key == null
      return this
    # Handle both `"key", value` and `{key: value}` -style arguments.
    if typeof key == 'object'
      attrs = key
      options = val
    else
      attrs = {}
      attrs[key] = val
    options = options or {}
    # Run validation.
    # TODO: Need to work on this so that we can validate nested models
    if !@_validate(attrs, options)
      return false
    # Extract attributes and options.
    unset = options.unset
    silent = options.silent
    changes = []
    changing = @_changing
    skipNested = options.skipNested
    @_changing = true
    if !changing
      @_setChanging()
    # Check for changes of `id`.
    if @idAttribute of attrs
      @id = attrs[@idAttribute]
    # For each `set` attribute, update or delete the current value.

    unsetAttribute = (destination, realKey) ->
      delete destination.attributes[realKey]
      return

    for attr of attrs
      `attr = attr`
      val = attrs[attr]
      if @_setChange(attr, val, options)
        changes.push attr
      if unset
        walkNestedAttributes this, attr, unsetAttribute
      else
        if skipNested
          @attributes[attr] = val
        else
          @_nestedSet attr, val, options
    # Trigger all relevant attribute changes.
    if !silent
      @_triggerChanges changes, options
    # You might be wondering why there's a `while` loop here. Changes can
    # be recursively nested within `"change"` events.
    if changing
      return this
    if !silent
      while @_pending
        @_pending = false
        @trigger 'change', this, options
    @_pending = false
    @_changing = false
    this
  get: (attr) ->
    nestedAttrs = if attr then attr.split('.') else []
    if nestedAttrs.length > 1
      nestedAttr = @attributes[_.first(nestedAttrs)]
      if !nestedAttr
        return
      rest = _.rest(nestedAttrs).join('.')
      if _.isFunction(nestedAttr.get)
        return nestedAttr.get(rest)
      return nestedAttr[rest]
    @attributes[attr]
  toJSON: (options) ->
    options = options or {}
    unsafeAttributes = _.result(this, 'unsafeAttributes')
    if options.except
      unsafeAttributes = _.union(unsafeAttributes, options.except)
    attributes = _.clone(@attributes)
    _.each unsafeAttributes, (attr) ->
      delete attributes[attr]
      return
    _.each attributes, (val, key) ->
      if val and _.isFunction(val.toJSON)
        attributes[key] = val.toJSON()
      return
    attributes
  hasChanged: (attr) ->
    if attr == null
      return !_.isEmpty(@changed)
    hasObjectKey @changed, attr
  previous: (attr) ->
    if attr == null or !@_previousAttributes
      return null
    getObjectValue @_previousAttributes, attr
  clear: (options) ->
    attrs = {}
    @id = undefined
    for key of @attributes
      val = @attributes[key]
      if val instanceof Backbone.Model
        val.clear()
      else if val instanceof Backbone.Collection
        val.reset()
      else
        @unset key
    this
)
module.exports = SuperModel
