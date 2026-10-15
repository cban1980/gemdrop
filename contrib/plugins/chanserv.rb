# Channel services: registered channels, their access lists and hostmask
# entries, the commands to manage them, and automatic op/voice.
#
#   UP <#chan> / DOWN <#chan>                 give or remove your own modes
#   OP|DEOP|VOICE|DEVOICE <#chan> [nick]      for channel ops
#   ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...
#   CHANREGISTER <#chan> <owner> [key]        bot admins
#   CHANDROP <#chan>                          the channel's owner
#   CHANKEY <#chan> <key>|-                   its key (+k), for joining; owner
#   MLOCK <#chan> [<modes> [params]|-]        modes the bot keeps set; owner
#
# A mode lock ("+ntk-i secret") is enforced wherever the bot has op: a
# locked mode someone changes is set back, at once and on a check every
# minute (so also after the bot joins or gets op). Corrections are
# limited per channel, so the bot never fights another bot or service.
#
# Identified users get their mode when they join a registered channel, or
# when they identify while in it; hostmask entries give it without
# identifying. New access and masks apply to who is in the channel at once
# (or within a minute, when changed from the command line), and so does the
# bot getting op; what an op takes from someone stays taken until they
# rejoin. Levels rank voice < op < owner; bot admins count as owner
# everywhere.
#
# The data (which channels are registered, their access lists and masks)
# belongs to the bot, not this plugin: it stays when the plugin is unloaded,
# the bot keeps joining registered channels, and bin/gemdrop-account manages
# it from the shell. Without this plugin there are just no channel commands
# and no automatic modes.
#
# Install:  bin/gemdrop-docker plugin install contrib/plugins/chanserv.rb
class Chanserv < Gemdrop::Plugin
  description "Registered channels: access lists, hostmasks, op/voice commands and automatic modes"
  help_group "Channel"

  MODE_COMMANDS = { "OP" => "+o", "DEOP" => "-o", "VOICE" => "+v", "DEVOICE" => "-v" }.freeze
  MODES = { "voice" => "v", "op" => "o", "owner" => "o" }.freeze # the mode each level gets

  help_topic "levels", <<~TEXT, summary: "channel access levels"
    Registered channels give accounts voice, op or owner access (voice < op < owner).
    You get your mode when you join while identified, or when you identify while in the channel.
    You can only grant levels below your own; bot admins count as owner everywhere.
  TEXT

  # --- automatic modes ---------------------------------------------------------------

  # The higher of the identified account's level and any matching mask.
  on(:join) do |event|
    next if same_name?(event.nick, bot_nick) || !registry.registered?(event.channel)

    forget_removed(event.channel, event.nick)
    level, mask = member_level(event.channel, event.nick, event.userhost)
    if grant(event.channel, event.nick, level) && mask
      log.info("#{event.prefix} matches mask #{mask} on #{event.channel}: giving #{level}")
    end
  end

  # What an op took from someone is left alone until they leave or rejoin.
  on(:part) { |event| forget_removed(event.channel, event.nick) }
  on(:kick) { |event| forget_removed(event.channel, event.nick) }
  on(:quit) { |event| @removed.delete_if { |(_, nick, _), _| nick == casefold(event.nick) } }
  on(:nick) do |event|
    @removed.keys.select { |(_, nick, _)| nick == casefold(event.nick) }.each do |key|
      @removed.delete(key)
      @removed[[key[0], casefold(event.new_nick), key[2]]] = true
    end
  end

  # Someone identified while already in registered channels.
  on(:identified) do |event|
    channels.each do |channel|
      next unless user(channel, event.nick) && registry.registered?(channel)

      level = access_level(channel, event.account)
      grant(channel, event.nick, level) if level
    end
  end

  # --- commands ------------------------------------------------------------------------

  command "UP", usage: "UP <#chan>", help: "give yourself your modes (voice or op)", access: "voice" do |ctx, args|
    answer(ctx) do
      usage!("UP <#chan>") unless args.size == 1
      channel = args[0]
      _account, level = require_level(ctx, channel, "voice")
      require_on_channel(channel, ctx.nick)
      raise Gemdrop::Error, "You already have #{mode_name(MODES[level])} in #{channel}." if has_mode?(channel, ctx.nick, MODES[level])

      require_op!(channel)
      mode(channel, "+#{MODES[level]}", ctx.nick)
    end
  end

  command "DOWN", usage: "DOWN <#chan>", help: "remove your own modes", access: "voice" do |ctx, args|
    answer(ctx) do
      usage!("DOWN <#chan>") unless args.size == 1
      channel = args[0]
      require_level(ctx, channel, "voice")
      require_on_channel(channel, ctx.nick)
      member = user(channel, ctx.nick)
      modes = MODES.values.uniq.select { |m| member&.modes.to_s.include?(m) }
      raise Gemdrop::Error, "You have no op or voice in #{channel}." if modes.empty?

      require_op!(channel)
      mode(channel, "-#{modes.join}", *([ctx.nick] * modes.size))
    end
  end

  { "OP" => "give op", "DEOP" => "take op", "VOICE" => "give voice", "DEVOICE" => "take voice" }.each do |name, help|
    details = name.start_with?("DE") ? "Users with equal or higher access are protected." : "Without a nick, you."
    command name, usage: "#{name} <#chan> [nick]", help: help, details: details, access: "op" do |ctx, args|
      answer(ctx) { set_user_mode(ctx, name, args) }
    end
  end

  command "ACCESS", usage: "ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...", help: "manage a channel's access list",
                    access: "op",
                    details: "ACCESS <#chan> LIST shows the list.\n" \
                             "ACCESS <#chan> ADD <account> <voice|op> gives access (only levels below your own).\n" \
                             "ACCESS <#chan> DEL <account> removes it.\n" \
                             "ACCESS <#chan> ADDMASK <nick!user@host> <voice|op> and DELMASK <mask>: auto-modes by " \
                             "hostmask (bot admins only)." do |ctx, args|
    answer(ctx) { access(ctx, args) }
  end

  command "CHANREGISTER", usage: "CHANREGISTER <#chan> <owner> [key]", help: "register a channel with the bot",
                          details: "With a key, the bot joins it with that key (a channel with +k).",
                          access: "admin", secret: 2 do |ctx, args|
    answer(ctx) do
      account = require_account(ctx)
      usage!("CHANREGISTER <#chan> <owner> [key]") unless [2, 3].include?(args.size)
      raise Gemdrop::Error, "Only bot admins can register channels." unless admin?(account)

      channel, owner_name, channel_key = args
      owner = account_name(owner_name) or raise Gemdrop::Error, "No account named #{owner_name}."
      registry.register(channel, owner, channel_key: channel_key)
      log.info("#{account} registered #{channel} for #{owner}")
      sync_channels # joins it
      tell(ctx, "#{channel} registered with owner #{owner}.")
    end
  end

  command "CHANDROP", usage: "CHANDROP <#chan>", help: "drop a registered channel", access: "owner" do |ctx, args|
    answer(ctx) do
      usage!("CHANDROP <#chan>") unless args.size == 1
      channel = args[0]
      account, = require_level(ctx, channel, "owner")
      store_lock(channel, nil) if mode_lock(channel) # before the drop: it reads the registration
      registry.drop(channel)
      log.info("#{account} dropped #{channel}")
      sync_channels(part_reason: "Channel dropped") # leaves it, unless it is in the config
      tell(ctx, "#{channel} has been dropped.")
    end
  end

  command "CHANKEY", usage: "CHANKEY <#chan> <key>|-", help: "the key the bot joins a channel with",
                     details: "For a channel with +k. - removes it. To also keep +k set, lock it: MLOCK <#chan> +k <key>.",
                     access: "owner", secret: 1 do |ctx, args|
    answer(ctx) do
      usage!("CHANKEY <#chan> <key>|-") unless args.size == 2
      channel, channel_key = args
      account, = require_level(ctx, channel, "owner")
      registry.set_channel_key(channel, channel_key == "-" ? nil : channel_key)
      log.info("#{account} #{channel_key == '-' ? 'removed' : 'set'} the key of #{channel}")
      sync_channels # joins it now if the key was what kept the bot out
      tell(ctx, channel_key == "-" ? "#{channel} has no key now." : "I join #{channel} with that key from now on.")
    end
  end

  command "MLOCK", usage: "MLOCK <#chan> [<modes> [params]|-]", help: "modes the bot keeps set in a channel",
                   details: "MLOCK #chan +nt-i keeps n and t set and i unset; +k <key> and +l <limit> take values. " \
                            "When someone changes a locked mode, the bot sets it back (it needs op). " \
                            "Without modes: the lock; - removes it.",
                   access: "owner", secret: 1 do |ctx, args|
    answer(ctx) do
      usage!("MLOCK <#chan> [<modes> [params]|-]") if args.empty?
      channel, *spec = args
      if spec.empty?
        lock = (require_level(ctx, channel, "op") && mode_lock(channel))
        next tell(ctx, lock ? "#{channel} is locked to #{shown(lock)}." : "#{channel} has no mode lock.")
      end

      account, = require_level(ctx, channel, "owner")
      if spec == ["-"]
        store_lock(channel, nil)
        log.info("#{account} removed the mode lock of #{channel}")
        next tell(ctx, "#{channel} has no mode lock now.")
      end

      lock = canonical_lock(spec.join(" "))
      store_lock(channel, lock)
      registry.set_channel_key(channel, lock_key(lock)) if lock_key(lock) # the key it joins with, too
      log.info("#{account} locked the modes of #{channel} to #{shown(lock)}")
      tell(ctx, "#{channel} is locked to #{shown(lock)}#{op?(channel) ? '.' : '; I need op there to keep it.'}")
      enforce(channel)
    end
  end

  # --- mode locks ----------------------------------------------------------------------

  # Someone changed modes: set locked ones back. The bot getting op checks
  # the whole lock.
  on(:mode) do |event|
    next unless event.channel && registry.registered?(event.channel)

    by_bot = same_name?(event.nick.to_s, bot_nick)
    note_removals(event) unless by_bot
    got_op = event.modes.any? { |change| change.mode == "o" && change.set && same_name?(change.param, bot_nick) }
    enforce(event.channel) if got_op || !by_bot
    apply_access(event.channel) if got_op
  end

  # The channel's mode lock ("+ntk-i key"), or nil. Other plugins may ask
  # (plugin("chanserv")&.mode_lock(channel)); the AI agent does.
  def mode_lock(channel)
    registry.registered?(channel) ? data.to_h.dig("mode_locks", casefold(channel)) : nil
  end

  def setup
    @lock_warned = {}
    @removed = {} # [channel, nick, mode] an op took from someone, folded
    # Also brings in access and masks changed from the command line.
    every(60) do
      registry.names.each do |channel|
        next unless in_channel?(channel)

        enforce(channel)
        apply_access(channel)
      end
    end
  end

  private

  # Sets back what differs from the channel's mode lock, if the bot has op.
  def enforce(channel)
    lock = mode_lock(channel) or return
    return unless op?(channel)

    plus, minus = parse_lock(lock)
    changes = lock_corrections(channel_modes(channel), plus, minus)
    return if changes.empty?

    unless rate_limit("mlock:#{casefold(channel)}", limit: 6, per: 60)
      log.warn("Not enforcing the mode lock on #{channel} for now: its modes keep being changed back") unless
        @lock_warned[channel]
      @lock_warned[channel] = true
      return
    end
    @lock_warned.delete(channel)
    send_modes(channel, changes)
    log.info("Mode lock on #{channel}: set #{describe(changes)}")
  rescue Gemdrop::Error => e
    log.warn("The mode lock on #{channel} can't be used: #{e.message}")
  end

  # [[sign, mode, value], ...] that make the current modes match the lock.
  def lock_corrections(current, plus, minus)
    changes = []
    plus.each do |mode, value|
      next if value == true ? current.key?(mode) : current[mode].to_s == value
      next if mode == "k" && current[mode] == "*" # the server hides it; it is set

      changes << ["-", "k", current["k"]] if mode == "k" && current.key?("k") # a key is replaced, not overwritten
      changes << ["+", mode, value == true ? nil : value]
    end
    minus.each do |mode|
      changes << ["-", mode, mode == "k" ? current["k"].to_s.then { |k| k.empty? ? "*" : k } : nil] if current.key?(mode)
    end
    changes
  end

  def send_modes(channel, changes)
    per_line = (isupport["MODES"].to_s.to_i.positive? ? isupport["MODES"].to_i : 3).clamp(1, 6)
    changes.each_slice(per_line) do |slice|
      modestring = +""
      sign = nil
      slice.each do |change_sign, mode, _value|
        modestring << change_sign if change_sign != sign
        sign = change_sign
        modestring << mode
      end
      mode(channel, modestring, *slice.filter_map { |_, _, value| value })
    end
  end

  # The lock as given ("+ntk-i secret"), checked against the modes the
  # server has, in a standard form. Raises Error if it isn't valid.
  def canonical_lock(text)
    plus, minus = parse_lock(text)
    flags = plus.keys.join
    values = plus.values.reject { |v| v == true }
    "#{"+#{flags}" unless flags.empty?}#{"-#{minus.join}" unless minus.empty?}#{" #{values.join(' ')}" if values.any?}"
  end

  # {mode => value or true} to keep set, [modes] to keep unset.
  def parse_lock(text)
    modes, *params = text.split
    raise Gemdrop::Error, "Modes look like +nt-i (with values for k and l)." unless modes.to_s.match?(/\A(?:[+-][A-Za-z]+)+\z/)

    lists, always, when_set, flags = (isupport["CHANMODES"].to_s.split(",", -1) + ["", "", "", ""]).first(4).map(&:chars)
    status = isupport["PREFIX"].to_s[/\((\w+)\)/, 1].to_s.chars
    plus = {}
    minus = []
    sign = "+"
    modes.each_char do |char|
      next sign = char if "+-".include?(char)
      raise Gemdrop::Error, "+#{char} is a list or status mode; it can't be locked." if lists.include?(char) || status.include?(char)
      raise Gemdrop::Error, "This server has no channel mode #{char}." unless (always + when_set + flags).include?(char)

      if sign == "-"
        minus |= [char]
        plus.delete(char)
        next
      end
      value = true
      if always.include?(char) || when_set.include?(char)
        value = params.shift or raise Gemdrop::Error, "+#{char} needs a value."
        raise Gemdrop::Error, "+l needs a number." if char == "l" && !value.match?(/\A[1-9]\d{0,5}\z/)
        raise Gemdrop::Error, "A key can't have commas or control characters." if char == "k" && !valid_channel_key?(value)
      end
      plus[char] = value
      minus.delete(char)
    end
    raise Gemdrop::Error, "Too many values: #{params.join(' ')}" if params.any?

    [plus, minus]
  end

  # "+n -i +l 50 +k *": the changes as logged, keys hidden.
  def describe(changes)
    changes.map { |sign, mode, value| "#{sign}#{mode}#{" #{mode == 'k' ? '*' : value}" if value}" }.join(" ")
  end

  def store_lock(channel, lock)
    data.update do |stored|
      locks = (stored["mode_locks"] ||= {})
      lock ? locks[casefold(channel)] = lock : locks.delete(casefold(channel))
    end
  end

  # The key a lock sets ("+ntk secret" => "secret"), or nil.
  def lock_key(lock)
    modes, *values = lock.to_s.split
    sign = "+"
    modes.to_s.each_char do |char|
      next sign = char if "+-".include?(char)
      next unless sign == "+" && %w[k l].include?(char)
      return values.first if char == "k"

      values.shift
    end
    nil
  end

  # A lock as shown to users: the key hidden.
  def shown(lock)
    key = lock_key(lock)
    key ? lock.sub(/ #{Regexp.escape(key)}(?= |\z)/, " *") : lock
  end

  def set_user_mode(ctx, command, args)
    usage!("#{command} <#chan> [nick]") unless [1, 2].include?(args.size)
    channel, target = args
    target ||= ctx.nick
    account, my_level = require_level(ctx, channel, "op")
    raise Gemdrop::Error, "I don't change my own modes." if same_name?(target, bot_nick)

    require_on_channel(channel, target)
    change = MODE_COMMANDS.fetch(command)
    if change.start_with?("-") && !same_name?(target, ctx.nick)
      # Protect users whose stored access is not below the requester's.
      target_account = account_for(target)
      if target_account && rank(access_level(channel, target_account)) >= rank(my_level)
        raise Gemdrop::Error, "#{target} has equal or higher access on #{channel}."
      end
    end
    letter = change[1]
    has = user(channel, target)&.modes.to_s.include?(letter)
    raise Gemdrop::Error, "#{target} already has #{mode_name(letter)} in #{channel}." if change.start_with?("+") && has
    raise Gemdrop::Error, "#{target} has no #{mode_name(letter)} in #{channel}." if change.start_with?("-") && !has

    require_op!(channel)
    log.info("#{account} (#{ctx.nick}) set #{change} on #{target} in #{channel}")
    mode(channel, change, target)
  end

  # Gives nick the mode of its level in channel, unless it has it (op
  # counts for voice too) or I can't (no op there). True when it did.
  def grant(channel, nick, level)
    return false if level.nil? || has_mode?(channel, nick, MODES[level]) || !op?(channel)

    mode(channel, "+#{MODES[level]}", nick)
    true
  end

  # The level someone gets in channel, and the mask that gives it if it is
  # a mask: the higher of their identified account's level and any mask.
  def member_level(channel, nick, userhost)
    account = account_for(nick, userhost)
    account_level = account && access_level(channel, account)
    mask_level, mask = userhost ? registry.mask_level(channel, "#{nick}!#{userhost}") : nil
    level_rank(mask_level) > level_rank(account_level) ? [mask_level, mask] : [account_level, nil]
  end

  # Gives the members already in channel what joining would give them, so
  # new access and masks take effect at once. Nothing an op took from
  # someone since they joined is given back.
  def apply_access(channel)
    return unless registry.registered?(channel) && in_channel?(channel) && op?(channel)

    wanted = { "o" => [], "v" => [] }
    users(channel).each do |member|
      next if same_name?(member.nick, bot_nick)

      level, = member_level(channel, member.nick, member.userhost)
      letter = level && MODES[level]
      next unless letter
      next if has_mode?(channel, member.nick, letter) || @removed[[casefold(channel), casefold(member.nick), letter]]

      wanted[letter] << member.nick
    end
    op(channel, *wanted["o"]) if wanted["o"].any?
    voice(channel, *wanted["v"]) if wanted["v"].any?
    wanted.each do |letter, nicks|
      log.info("#{channel}: giving #{mode_name(letter)} to #{nicks.join(', ')} by their access") if nicks.any?
    end
  end

  def note_removals(event)
    event.modes.each do |change|
      next unless %w[o v].include?(change.mode) && change.param

      key = [casefold(event.channel), casefold(change.param), change.mode]
      change.set ? @removed.delete(key) : (@removed[key] = true)
    end
  end

  def forget_removed(channel, nick)
    %w[o v].each { |letter| @removed.delete([casefold(channel), casefold(nick), letter]) }
  end

  def has_mode?(channel, nick, letter)
    modes = user(channel, nick)&.modes.to_s
    modes.include?(letter) || (letter == "v" && modes.include?("o"))
  end

  def require_op!(channel)
    raise Gemdrop::Error, "I need op in #{channel} for that." unless op?(channel)
  end

  def mode_name(letter) = letter == "o" ? "op" : "voice"

  def access(ctx, args)
    channel, sub, *rest = args
    usage!("ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...") unless channel && sub
    return access_mask(ctx, channel, sub.upcase, rest) if %w[ADDMASK DELMASK].include?(sub.upcase)

    account, my_level = require_level(ctx, channel, "op")
    case sub.upcase
    when "LIST"
      registry.access_list(channel).each { |name, level| tell(ctx, "#{channel}: #{name} #{level}") }
      registry.masks(channel).each { |mask, level, by| tell(ctx, "#{channel}: mask #{mask} #{level} (added by #{by})") }
    when "ADD"
      usage!("ACCESS <#chan> ADD <account> <voice|op>") unless rest.size == 2
      target = existing_account(rest[0])
      level = rest[1].downcase
      raise Gemdrop::Error, "You can only grant levels below your own (#{my_level})." unless rank(level) < rank(my_level)

      check_outranks(channel, target, my_level)
      registry.set_access(channel, target, level)
      log.info("#{account} gave #{target} #{level} access on #{channel}")
      tell(ctx, "#{target} now has #{level} access on #{channel}.")
      apply_access(channel)
    when "DEL"
      usage!("ACCESS <#chan> DEL <account>") unless rest.size == 1
      target = existing_account(rest[0])
      check_outranks(channel, target, my_level)
      registry.remove_access(channel, target)
      log.info("#{account} removed #{target}'s access on #{channel}")
      tell(ctx, "Removed #{target} from #{channel}.")
    else
      usage!("ACCESS <#chan> LIST|ADD|DEL|ADDMASK|DELMASK ...")
    end
  end

  # Hostmask entries give voice/op on join without identifying, so only
  # bot admins may manage them (on any registered channel).
  def access_mask(ctx, channel, sub, rest)
    account = require_account(ctx)
    raise Gemdrop::Error, "Only bot admins can manage masks." unless admin?(account)
    raise Gemdrop::Error, "#{channel} is not registered." unless registry.registered?(channel)

    if sub == "ADDMASK"
      usage!("ACCESS <#chan> ADDMASK <nick!user@host> <voice|op>") unless rest.size == 2
      mask = registry.add_mask(channel, rest[0], rest[1].downcase, added_by: account)
      log.info("#{account} added mask #{mask} (#{rest[1].downcase}) on #{channel}")
      tell(ctx, "Mask #{mask} now gets #{rest[1].downcase} on #{channel}, also who is there now.")
      apply_access(channel)
    else
      usage!("ACCESS <#chan> DELMASK <nick!user@host>") unless rest.size == 1
      registry.remove_mask(channel, rest[0])
      log.info("#{account} removed mask #{rest[0]} on #{channel}")
      tell(ctx, "Removed mask #{rest[0]} from #{channel}.")
    end
  end

  # --- checks ----------------------------------------------------------------------------

  def require_account(ctx) = ctx.account || raise(Gemdrop::Error, "You must IDENTIFY first.")

  # Returns [account, level] or raises if the user lacks min_level.
  def require_level(ctx, channel, min_level)
    account = require_account(ctx)
    raise Gemdrop::Error, "#{channel} is not registered." unless registry.registered?(channel)

    level = access_level(channel, account)
    raise Gemdrop::Error, "You need #{min_level} access on #{channel} for that." if rank(level) < rank(min_level)

    [account, level]
  end

  def require_on_channel(channel, nick)
    raise Gemdrop::Error, "#{nick} is not on #{channel}." unless user(channel, nick)
  end

  def existing_account(name) = account_name(name) || raise(Gemdrop::Error, "No account named #{name}.")

  def check_outranks(channel, target, my_level)
    return if rank(access_level(channel, target)) < rank(my_level)

    raise Gemdrop::Error, "#{target} has equal or higher access on #{channel}."
  end

  # --- helpers ----------------------------------------------------------------------------

  # Runs a command; an Error is the answer. Replies can echo user input
  # (channel or account names), so formatting and control codes go first.
  def answer(ctx)
    yield
  rescue Gemdrop::Error => e
    tell(ctx, e.message)
  end

  def tell(ctx, text) = ctx.reply_privately(plain_text(text))

  def rank(level) = level_rank(level)
end
