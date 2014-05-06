getUserGroup = (userId) ->
  return unless userId
  # No side effects from admin, please
  return if Meteor.users.findOne(userId)?.admin
  return Partitioner.getUserGroup(userId)

###
  Connect callbacks
###

UserStatus.events.on "connectionLogin", (doc) ->
  # Update ip address in assignments for this worker
  user = Meteor.users.findOne(doc.userId)
  return if user?.admin

  # TODO verify this is valid as we reject multiple connections on login
  Assignments.update {
    workerId: user.workerId
    status: "assigned"
  }, {
    $set: {ipAddr: doc.ipAddr}
  }

  return

connectCallbacks = []

UserStatus.events.on "connectionLogin", (doc) ->
  return unless (groupId = getUserGroup(doc.userId))?
  treatment = TurkServer.Experiment.getTreatment(groupId)
  Partitioner.bindGroup groupId, ->
    TurkServer.log
      _userId: doc.userId
      _meta: "connected"

    _.each connectCallbacks, (cb) ->
      try
        cb.call
          userId: doc.userId
          treatment: treatment
      catch e
        Meteor._debug "Exception in user connect callback: " + e

TurkServer.onConnect = (func) ->
  connectCallbacks.push func

###
  Disconnect callbacks
###

UserStatus.events.on "connectionLogout", (doc) ->
  # Remove disconnected users from lobby, if they are there
  TurkServer.Lobby.removeUser(doc.userId)

disconnectCallbacks = []

UserStatus.events.on "connectionLogout", (doc) ->
  return unless (groupId = getUserGroup(doc.userId))?
  treatment = TurkServer.Experiment.getTreatment(groupId)
  Partitioner.bindGroup groupId, ->
    TurkServer.log
      _userId: doc.userId
      _meta: "disconnected"

    _.each disconnectCallbacks, (cb) ->
      try
        cb.call
          userId: doc.userId
          treatment: treatment
      catch e
        Meteor._debug "Exception in user disconnect callback: " + e

TurkServer.onDisconnect = (func) ->
  disconnectCallbacks.push func

###
  Idle and returning from idle
###

idleCallbacks = []
activeCallbacks = []

TurkServer.onIdle = (func) -> idleCallbacks.push(func)
TurkServer.onActive = (func) -> idleCallbacks.push(func)

# TODO: compute total amount of time a user has been idle in a group

UserStatus.events.on "connectionIdle", (doc) ->
  return unless (groupId = getUserGroup(doc.userId))?
  treatment = TurkServer.Experiment.getTreatment(groupId)
  Partitioner.bindGroup groupId, ->
    TurkServer.log
      _userId: doc.userId
      _meta: "idle"
      _timestamp: doc.lastActivity # Overridden to a past value

    _.each idleCallbacks, (cb) ->
      try
        cb.call
          userId: doc.userId
          treatment: treatment
      catch e
        Meteor._debug "Exception in user idle callback: " + e

UserStatus.events.on "connectionActive", (doc) ->
  return unless (groupId = getUserGroup(doc.userId))?
  treatment = TurkServer.Experiment.getTreatment(groupId)
  Partitioner.bindGroup groupId, ->
    TurkServer.log
      _userId: doc.userId
      _meta: "active"
      _timestamp: doc.lastActivity # Also overridden

    _.each activeCallbacks, (cb) ->
      try
        cb.call
          userId: doc.userId
          treatment: treatment
      catch e
        Meteor._debug "Exception in user active callback: " + e

###
  Methods
###

getCurrentAssignment = (userId) ->
  userId = Meteor.userId() unless userId?
  return unless userId?
  user = Meteor.users.findOne(userId)
  Assignments.findOne
    workerId: user.workerId
    status: "assigned"

getCurrentBatch = (userId)->
  assignment = getCurrentAssignment(userId)
  return unless assignment?
  Batches.findOne(assignment.batchId)


Meteor.methods
  "ts-set-username": (username) ->
    # TODO may need validation here due to bad browsers/bad people
    userId = Meteor.userId()
    return unless userId
    if Partitioner.directOperation(-> Meteor.users.findOne(username: username))
      throw new Meteor.Error(409, ErrMsg.usernameTaken)
    Meteor.users.update userId,
      $set: {username: username}

  "ts-record-inactive": (data) ->
    # TODO implement tracking inactivity
    # We don't trust client timestamps, but only as identifier and use difference
    console.log data.start, data.time

  "ts-submit-exitdata": (doc, panel) ->
    userId = Meteor.userId()
    throw new Meteor.Error(403, ErrMsg.authErr) unless userId
    user = Meteor.users.findOne(userId)

    # check that the user is allowed to do this
    throw new Meteor.Error(403, ErrMsg.stateErr) unless user?.turkserver?.state is "exitsurvey"

    # TODO what if this doesn't exist?
    asst = getCurrentAssignment()

    # mark assignment as completed and save the data
    Assignments.update asst._id,
      $set: {
        status: "completed"
        submitTime: Date.now()
        exitdata: doc
      }

    # TODO schedule this worker's resume token to be scavenged in the future

    # Update worker contact info
    # TODO generalize this
    if panel
      Workers.upsert user.workerId,
        $set:
          contact: panel.contact
          times: panel.times

    Meteor.users.update userId,
      $unset: {"turkserver.state": null}

    # return true to auto submit the HIT
    return true

TurkServer.handleConnection = (doc) ->

  # TODO Does the worker need to take quiz/tutorial?

  # Is worker in part of an active group (experiment)?
  # This is okay even if no active batch
  if Partitioner.getUserGroup(doc.userId)
    Meteor._debug doc.userId + " is reconnecting to an existing group"
    # other reconnection info recorded above
    return

  # Is the worker reconnecting to an exit survey?
  if Meteor.users.findOne(doc.userId)?.turkserver?.state is "exitsurvey"
    Meteor._debug doc.userId + " is reconnecting to the exit survey"
    # Wait for them to fill it out
    return

  # None of the above, throw them into the assignment mechanism
  batch = getCurrentBatch(doc.userId)
  throw new Meteor.Error(403, "No batch associated with assignment") unless batch?

  if batch.grouping is "groupSize" and batch.lobby
    TurkServer.Lobby.addUser(doc.userId)
  else if batch.grouping is "groupCount"
    TurkServer.assignUserRoundRobin(doc.userId)
  else
    TurkServer.assignUserSequential(doc.userId)

# TODO fix up the stuff below to assign treatments properly

# Assignment from lobby
TurkServer.assignAllUsers = (userIds) ->
  # TODO don't just assign a random treatment
  batch = getCurrentBatch(userIds[0])
  treatmentId = _.sample batch.treatmentIds
  treatment = Treatments.findOne(treatmentId)
  newId = TurkServer.Experiment.create(batch, treatment)
  TurkServer.Experiment.setup(newId)

  _.each userIds, (userId) ->
    TurkServer.Experiment.addUser(newId, userId)

# Assignment for fixed group count
TurkServer.assignUserRoundRobin = (userId) ->
  experimentIds = getCurrentBatch(userId).experimentIds
  exp = _.min Experiments.find(_id: $in: experimentIds).fetch(), (ex) ->
    Grouping.find(groupId: ex._id).count()

  TurkServer.Experiment.addUser(exp._id, userId)

# Assignment for no lobby fixed group size
TurkServer.assignUserSequential = (userId) ->
  batch = getCurrentBatch(userId)

  assignedToExisting = false
  Experiments.find(assignable: true).forEach (exp) ->
    return if assignedToExisting # Break loop if already assigned
    if Grouping.find(groupId: exp._id).count() < batch.groupVal
      TurkServer.Experiment.addUser(exp._id, userId)
      assignedToExisting = true

  return if assignedToExisting

  # Create a new experiment
  # TODO find a treatment
  treatmentId = _.sample batch.treatmentIds
  treatment = Treatments.findOne(treatmentId)
  newId = TurkServer.Experiment.create batch, treatment,
    assignable: true
  TurkServer.Experiment.setup(newId)
  TurkServer.Experiment.addUser(newId, userId)



