class TurkServer.Timers
  # Start a new round; callback is triggered at the end of the round
  # only if the round is not ended prematurely
  # We can't actually store the timeout in the database
  # TODO make round ends work properly over a code reload
  @startNewRound: (startTime, endTime, callback) ->
    interval = endTime - new Date()
    throw new Error("endTime is in the past") if interval < 0

    if (currentRound = RoundTimers.findOne(active: true))?
      index = currentRound.index + 1

      # deactivate current round
      RoundTimers.update currentRound._id,
        $set:
          active: false
    else
      index = 1

    RoundTimers.insert
      index:      index
      startTime:  startTime
      endTime:    endTime
      active:     true

    if callback?
      # currentInvocation is removed, so we bind the group ourselves if we were called from inside a method
      # https://github.com/meteor/meteor/blob/devel/packages/meteor/timers.js
      currentGroup = Partitioner.group()
      Meteor.setTimeout( ->
        Partitioner.bindGroup currentGroup, ->
          # Check if there is an active round that hasn't ended yet
          # It may have ended due to the function below; otherwise, the time will have changed
          activeRound = RoundTimers.findOne
            index: index,
            active: true,
            endTime: endTime
          return unless activeRound

          callback()
      , interval)

    return

  # Set end time of current round
  # Should cancel timeout above
  @endCurrentRound: ->
    unless (currentRound = RoundTimers.findOne(active: true))?
      throw new Error("No current round to end")

    now = new Date()
    if currentRound.endTime < now
      throw new Error("Current round is already ended")

    RoundTimers.update currentRound._id,
      $set:
        endTime: now

    return
