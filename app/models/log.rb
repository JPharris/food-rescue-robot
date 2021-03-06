class Log < ActiveRecord::Base
  belongs_to :schedule # FIXME: remove after migrate
  belongs_to :recipient, :class_name => "Location", :foreign_key => "recipient_id" # FIXME: remove after migration
  belongs_to :food_type # FIXME: remove after migration

  belongs_to :schedule_chain
  has_many :log_volunteers
  has_many :volunteers, :through => :log_volunteers,
           :conditions=>{"log_volunteers.active"=>true}
  has_many :active_log_volunteers, :conditions=>{"active" => true}, :class_name => "LogVolunteer"
  has_many :inactive_log_volunteers, :conditions=>{"active" => false}, :class_name => "LogVolunteer"
  has_many :log_recipients
  has_many :recipients, :through => :log_recipients
  belongs_to :donor, :class_name => "Location", :foreign_key => "donor_id"
  belongs_to :scale_type
  belongs_to :transport_type
  belongs_to :region
  has_many :log_parts
  has_many :food_types, :through => :log_parts

  accepts_nested_attributes_for :log_volunteers
  accepts_nested_attributes_for :log_recipients
  accepts_nested_attributes_for :active_log_volunteers
  accepts_nested_attributes_for :schedule

  WhyZero = {1 => "No Food", 2 => "Didn't Happen"}

  validates :notes, presence: { if: Proc.new{ |a| a.complete and a.summed_weight == 0 and a.summed_count == 0 and a.why_zero == 2 },
             message: "can't be blank if weights/counts are all zero: let us know what happened!" }
  validates :transport_type_id, presence: { if: :complete }
  validates :donor_id, presence: { if: :complete }
  validates :scale_type_id, presence: { if: :complete }
  validates :when, presence: true
  validates :why_zero, presence: { if: Proc.new{ |a| a.complete and a.summed_weight == 0 and a.summed_count == 0 } }

  attr_accessible :schedule_id, :region_id, :donor_id, :why_zero,
                  :food_type_id, :transport_type_id, :flag_for_admin, :notes, 
                  :num_reminders, :transport, :when, :scale_type_id,
                  :log_volunteers_attributes, :weight_unit, :active_log_volunteers_attributes,
                  :schedule_chain_id, :log_recipients_attributes,
                  :id, :created_at, :updated_at, :complete, :recipient_ids, :volunteer_ids, :num_volunteers

  before_save { |record|
    return if record.region.nil?
    record.scale_type = record.region.scale_types.first if record.scale_type.nil? and record.region.scale_types.length == 1
    unless record.scale_type.nil?
      record.weight_unit = record.scale_type.weight_unit if record.weight_unit.nil?
      record.log_parts.each{ |lp|
        if record.weight_unit == "kg"
          lp.weight = (lp.weight * (1.0/2.2).to_f).round(2)
        elsif record.weight_unit == "st"
          lp.weight = (conv_weight * (1.0/14.0).to_f).round(2)
        end
        lp.save
      }
      record.weight_unit = "lb"
    end
  }

  after_save{ |record|
    record.log_volunteers.each{ |lv|
      lv.destroy if lv.volunteer_id.blank?
    }
    record.tweet
  }

  def has_volunteers?
    self.volunteers.count > 0
  end

  def no_volunteers?
    self.volunteers.count == 0
  end

  def covered?
    nv = self.num_volunteers
    nv = self.schedule_chain.num_volunteers if nv.nil? and not self.schedule_chain.nil?
    nv.nil? ? self.has_volunteers? : self.volunteers.length >= nv
  end

  def has_volunteer? volunteer
    return false if volunteer.nil?
    self.volunteers.collect { |v| v.id }.include? volunteer.id
  end

  def summed_weight
    self.log_parts.collect{ |lp| lp.weight }.compact.sum
  end

  def summed_count
    self.log_parts.collect{ |lp| lp.count }.compact.sum
  end

  def prior_volunteers
    self.log_volunteers.collect{ |sv| (not sv.active) ? sv.volunteer : nil }.compact
  end

  def owner_chain_id
    self.schedule.nil? ? nil: self.schedule.schedule_chain_id
  end

  #### TWITTER INTEGRATION (Currently not working?)

  TweetGainThreshold = 25000
  TweetTimeThreshold = 3600*24
  TweetGainOrTime = :gain

  def tweet
    return true if self.region.nil? or self.region.twitter_key.nil? or self.region.twitter_secret.nil? or self.region.twitter_token.nil? or
      self.region.twitter_token_secret.nil?
    return true unless self.complete

    poundage = Log.picked_up_weight(region.id)
    poundage += self.region.prior_lbs_rescued unless self.region.prior_lbs_rescued.nil?
    last_poundage = region.twitter_last_poundage.nil? ? 0.0 : region.twitter_last_poundage

    if TweetGainOrTime == :time
      return true unless self.region.twitter_last_timestamp.nil? or (Time.zone.now - self.region.twitter_last_timestamp) > TweetTimeThreshold
      # flip a coin about whether we'll post this one so we don't always post at the same time of day
      return true if rand > 0.5
    else
      return true unless (poundage - last_poundage >= TweetGainThreshold)
    end

    begin
      Twitter.configure do |config|
        config.consumer_key = self.region.twitter_key
        config.consumer_secret = self.region.twitter_secret
        config.oauth_token = self.region.twitter_token
        config.oauth_token_secret = self.region.twitter_token_secret
      end
      if poundage <= last_poundage
        region.twitter_last_poundage = poundage
        region.save
        return true
      end
      t = "#{self.volunteers.collect{ |v| v.name }.join(" and ")} picked up #{self.summed_weight.round} lbs of food, bringing
           us to #{poundage.round} lbs of food rescued to date in #{self.region.name}."
      if self.donor.twitter_handle.nil?
        t += "Thanks to #{self.donor.name} for the donation!"

      else
        t += " Thanks to @#{self.donor.twitter_handle} for the donation!"
      end
      return true if t.length > 140
      Twitter.update(t)
      self.region.twitter_last_poundage = poundage
      self.region.twitter_last_timestamp = Time.zone.now
      self.region.save
      flash[:notice] = "Tweeted: #{t}"
    rescue
      # Twitter update didn't work for some reason, but everything else seems to have...
    end
    return true
  end

  #### CLASS METHODS

  def self.pickup_count region_id
    Log.where(:region_id=>region_id, :complete=>true).count
  end

  def self.picked_up_by(volunteer_id,complete=true,limit=nil)
    if limit.nil?
      Log.joins(:log_volunteers).where("log_volunteers.volunteer_id = ? AND logs.complete=? AND log_volunteers.active",volunteer_id,complete).order('"logs"."when" DESC')
    else
      Log.joins(:log_volunteers).where("log_volunteers.volunteer_id = ? AND logs.complete=? AND log_volunteers.active",volunteer_id,complete).order('"logs"."when" DESC').limit(limit.to_i)
    end
  end

  def self.at(loc)
    if loc.is_donor
      return Log.joins(:food_types).select("sum(weight) as weight_sum, string_agg(food_types.name,', ') as food_types_combined, logs.id, logs.transport_type_id, logs.when").where("donor_id = ?",loc.id).group("logs.id, logs.transport_type_id, logs.when").order("logs.when ASC")
    else
      return Log.joins(:food_types,:recipients).select("sum(weight) as weight_sum,
          string_agg(food_types.name,', ') as food_types_combined, logs.id, logs.transport_type_id, logs.when, logs.donor_id").
          where("recipient_id=?",loc.id).group("logs.id, logs.transport_type_id, logs.when, logs.donor_id").order("logs.when ASC")
    end
  end

  def self.picked_up_weight(region_id=nil,volunteer_id=nil)
    cq = "logs.complete"
    vq = volunteer_id.nil? ? nil : "log_volunteers.volunteer_id=#{volunteer_id}"
    rq = region_id.nil? ? nil : "logs.region_id=#{region_id}"
    aq = "log_volunteers.active"
    Log.joins(:log_volunteers,:log_parts).where([cq,vq,rq,aq].compact.join(" AND ")).sum(:weight).to_f
  end

  def self.upcoming_for(volunteer_id)
    Log.joins(:log_volunteers).where("active AND \"when\" >= ? AND volunteer_id = ?",Time.zone.today,volunteer_id)
  end

  def self.past_for(volunteer_id)
    Log.joins(:log_volunteers).where("active AND \"when\" < ? AND volunteer_id = ?",Time.zone.today,volunteer_id)
  end

  def self.needing_coverage(region_id_list=nil,days_away=nil,limit=nil)
    unless region_id_list.nil?
      if days_away.nil?
        Log.where("\"when\" >= ?",Time.zone.today).where(:region_id=>region_id_list).limit(limit).reject{ |l| l.covered? }
      else
        Log.where("\"when\" >= ? AND \"when\" <= ?",Time.zone.today,Time.zone.today+days_away).where(:region_id=>region_id_list).limit(limit).reject{ |l| l.covered? }
      end
    else
      if days_away.nil?
        Log.where("\"when\" >= ?",Time.zone.today).limit(limit).reject{ |l| l.covered? }
      else
        Log.where("\"when\" >= ? AND \"when\" <= ?",Time.zone.today,Time.zone.today+days_away).limit(limit).reject{ |l| l.covered? }
      end
    end
  end

  # Turns a flat array into an array of arrays
  def self.group_by_schedule(logs)
    ret = []
    h = {}
    logs.each{ |l|
        if l.schedule_chain.nil?
        ret << [l]
      else
        k = [l.when,l.schedule_chain_id].join(":")
        if h[k].nil?
          h[k] = ret.length
          ret << []
        end
        ret[h[k]] << l
      end
    }
    ret
  end

  def self.being_covered region_id_list=nil
    unless region_id_list.nil?
      return self.select("logs.*, count(log_volunteers.volunteer_id) as prior_count").joins(:log_volunteers).
        where("NOT log_volunteers.active").
        where(:region_id=>region_id_list).
        where("\"when\" >= ?",Time.zone.today).
        group("logs.id")
    else
      return self.select("logs.*, count(log_volunteers.volunteer_id) as prior_count").joins(:log_volunteers).
        where("NOT log_volunteers.active").
        where("\"when\" >= ?",Time.zone.today).group("logs.id")
    end
  end

end
