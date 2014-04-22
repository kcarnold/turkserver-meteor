Handlebars.registerHelper "_tsDebug", ->
  console.log @, arguments

# Submit as soon as this template appears on the page.
Template.mturkSubmit.rendered = -> @find("form").submit()

Template.tsTimePicker.zone = -> moment().format("Z")

Template.tsTimeOptions.momentList = ->
  # Default time selections: 9AM EST to 11PM EST
  m = moment.utc(hours: 9 + 5).local()
  return (m.clone().add('hours', x) for x in [0..14])

# Store all values in GMT-5
Template.tsTimeOptions.valueFormatted = -> @zone(300).format('HH ZZ')

# Display values in user's timezone
Template.tsTimeOptions.displayFormatted = -> @local().format('hA [UTC]Z')

unescapeURL = (s) ->
  decodeURIComponent s.replace(/\+/g, "%20")

getURLParams = ->
  params = {}
  m = window.location.href.match(/[\\?&]([^=]+)=([^&#]*)/g)
  if m
    i = 0
    while i < m.length
      a = m[i].match(/.([^=]+)=(.*)/)
      params[unescapeURL(a[1])] = unescapeURL(a[2])
      i++
  return params

params = getURLParams()

TurkServer.submitHIT = -> UI.insert UI.render(Template.mturkSubmit), document.body

Handlebars.registerHelper "hitParams", params

Handlebars.registerHelper "hitIsViewing",
  params.assignmentId and params.assignmentId is "ASSIGNMENT_ID_NOT_AVAILABLE"

loginCallback = (e) ->
  return unless e?
  if e.message is ErrMsg.alreadyCompleted
    # submit the HIT
    TurkServer.submitHIT()
  else
    bootbox.dialog("<p>Unable to login:</p>" + e.message)

mturkLogin = (args) ->
  Accounts.callLoginMethod
    methodArguments: [ args ],
    userCallback: loginCallback

testLogin = ->
  # FIXME hack: never run this if we are live
  return if window.location.protocol is "https:" or window isnt window.parent
  # Don't try logging in if we are logged in or already have parameters
  return if Meteor.userId() or Session.get("_loginParams")
  # Don't show this if we are trying to get at the admin interface
  return if Router.current()?.path?.indexOf("/turkserver") is 0

  str = Random.id()
  hitId = str + "_HIT"
  asstId = str + "_Asst"
  workerId = str + "_Worker"
  prompt =
  """<p>TurkServer can create a fake user for testing purposes.</p>
       <p>Press <b>OK</b> to log in with the following credentials, or <b>Cancel</b> to stay logged out.</p>
        <br> HIT id: <b>#{hitId}</b>
        <br> Assignment id: <b>#{asstId}</b>
        <br> Worker id: <b>#{workerId}</b>
    """
  bootbox.confirm prompt, (result) ->
    return unless result
    console.log "Trying login with fake credentials"
    # Save parameters and login
    loginParams = {
      hitId: hitId
      assignmentId: asstId
      workerId: workerId
      test: true
    }
    Session.set("_loginParams", loginParams)
    mturkLogin(loginParams)

Meteor.startup ->
  # Remember our previous hit parameters unless they have been replaced
  # TODO make sure this doesn't interfere with actual HITs
  if params.hitId and params.assignmentId and params.workerId
    Session.set("_loginParams", {
      hitId: params.hitId
      assignmentId: params.assignmentId
      workerId: params.workerId
    })
    Meteor._debug "Captured login params"

  # Recover either page params or stored session params as above
  loginParams = Session.get("_loginParams")

  if loginParams
    Meteor._debug "Logging in with stored parameters"
    mturkLogin(loginParams)
  else
    # Give enough time to load before attempting login
    Meteor.setTimeout testLogin, 1000

# TODO Testing disconnect and reconnect, remove later
TurkServer.testingLogin = ->
  if Meteor.user()
    console.log "Already logged in."
    return
  unless Session.get("_loginParams")
    console.log "No parameters saved."
    return
  mturkLogin(Session.get("_loginParams"))

