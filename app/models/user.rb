class User < ActiveRecord::Base
  require 'community_engine_sha1_crypto_method'
  require 'paperclip'

  # Constants
  MALE    = 'M'
  FEMALE  = 'F'

  LEARNING_ACTIONS = ['answer', 'results', 'show']
  TEACHING_ACTIONS = ['create']

  SUPPORTED_CURRICULUM_TYPES = [ 'application/pdf', 'application/msword',
                                 'text/plain', 'application/rtf', 'text/rtf',
                                 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' # docx
                               ]

  # CALLBACKS
  before_create :make_activation_code
  after_create {|user| UserNotifier.signup_notification(user).deliver }
  after_create  :update_last_login
  # FIXME Verificar necessidade (não foi testado)
  after_save    :recount_metro_area_users
  # FIXME Verificar necessidade (não foi testado)
  after_destroy :recount_metro_area_users

  # ASSOCIATIONS
  has_many :annotations, :dependent => :destroy, :include=> :lecture
  has_many :statuses, :as => :statusable, :dependent => :destroy
  has_many :chat_messages
  # Space
  has_many :spaces, :through => :user_space_associations
  has_many :user_space_associations, :dependent => :destroy
  has_many :spaces_owned, :class_name => "Space" , :foreign_key => "owner"
  # Environment
  has_many :user_environment_associations, :dependent => :destroy
  has_many :environments, :through => :user_environment_associations
  has_many :user_course_associations, :dependent => :destroy
  has_many :environments_owned, :class_name => "Environment",
    :foreign_key => "owner"
  # Course
  has_many :courses, :through => :user_course_associations

  #COURSES
  has_many :lectures, :foreign_key => "owner",
    :conditions => {:is_clone => false, :published => true}
  has_many :courses_owned, :class_name => "Course",
    :foreign_key => "owner"
  has_many :exams, :foreign_key => "owner_id", :conditions => {:is_clone => false}
  has_many :exam_users#, :dependent => :destroy
  has_many :exam_history, :through => :exam_users, :source => :exam
  has_many :questions, :foreign_key => :author_id
  has_many :favorites, :order => "created_at desc", :dependent => :destroy
  # FIXME Verificar necessidade (Suggestion.rb não existe). Não foi testado.
  has_many :suggestions
  enumerate :role
  belongs_to  :metro_area
  belongs_to  :state
  belongs_to  :country
  has_many :recently_active_friends, :through => :friendships, :source => :friend,
    :order => "users.last_request_at ASC", :limit => 9,
    :conditions => "friendships.status = 'accepted'",
    :select => ["users.id, users.first_name, users.last_name, users.login, " + \
                "users.avatar_file_name, users.avatar_file_size, " + \
                "users.avatar_content_type"]

  #bulletins
  has_many :bulletins, :foreign_key => "owner"
  #enrollments
  has_many :enrollments, :dependent => :destroy

  #subject
  has_many :subjects, :order => 'title ASC',
    :conditions => { :finalized => true }

  #groups
  # FIXME Verificar necessidade (GroupUser.rb não existe). Não foi testado.
  has_many :group_user
  has_many :groups, :through => :group_user

  #student_profile
  has_many :student_profiles

  #forums
  has_many :moderatorships, :dependent => :destroy
  has_many :forums, :through => :moderatorships, :order => 'forums.name'
  has_many :sb_posts, :dependent => :destroy
  has_many :topics, :dependent => :destroy
  has_many :monitorships, :dependent => :destroy
  # FIXME Verificar necessidade (não foi testado)
  has_many :monitored_topics, :through => :monitorships, :conditions => ['monitorships.active = ?', true], :order => 'topics.replied_at desc', :source => :topic

  has_many :plans

  has_many :course_invitations, :class_name => "UserCourseAssociation",
    :conditions => ["state LIKE 'invited'"]
  has_one :settings, :class_name => "UserSetting", :dependent => :destroy

  # Named scopes
  scope :recent, order('users.created_at DESC')
  # FIXME Remover tudo relacionado a este named_scope,
  # featured_writer não existe no BD.
  scope :featured, where("users.featured_writer = ?", true)
  scope :active, where("users.activated_at IS NOT NULL")
  scope :with_ids, lambda { |ids| where(:id => ids) }
  scope :n_recent, lambda { |limit|
    order('users.last_request_at DESC').limit(limit)
  }
  scope :with_keyword, lambda { |keyword|
    where("LOWER(login) LIKE :keyword OR " + \
      "LOWER(first_name) LIKE :keyword OR " + \
      "LOWER(last_name) LIKE :keyword OR " +\
      "CONCAT(LOWER(first_name), ' ', LOWER(last_name)) LIKE :keyword OR " +\
      "LOWER(email) LIKE :keyword", { :keyword => "%#{keyword.downcase}%" }).
      limit(10).select("users.id, users.first_name, users.last_name, users.login, users.email, users.avatar_file_name")
  }

  attr_accessor :email_confirmation

  # Accessors
  attr_protected :admin, :featured, :role, :activation_code,
    :friends_count, :score, :removed,
    :sb_posts_count, :sb_last_seen_at

  accepts_nested_attributes_for :settings

  # PLUGINS
  acts_as_authentic do |c|
    c.crypto_provider = CommunityEngineSha1CryptoMethod

    c.validates_length_of_password_field_options = { :within => 6..20, :if => :password_required? }
    c.validates_length_of_password_confirmation_field_options = { :within => 6..20, :if => :password_required? }

    c.validates_length_of_login_field_options = { :within => 5..20 }
    c.validates_format_of_login_field_options = { :with => /^[A-Za-z0-9_-]+$/ }

    #FIXME Não está validando, verificar motivo. Foi adicionado um
    # validates_format_of.
    c.validates_length_of_email_field_options = { :within => 3..100 }
    c.validates_format_of_email_field_options = { :with => /^([^@\s]+)@((?:[-a-z0-9A-Z]+\.)+[a-zA-Z]{2,})$/ }
  end

  has_attached_file :avatar, Redu::Application.config.paperclip
  has_attached_file :curriculum, Redu::Application.config.paperclip

  has_friends
  ajaxful_rater
  acts_as_taggable
  has_private_messages

  # VALIDATIONS
  validates_presence_of     :login, :email, :first_name, :last_name,
    :email_confirmation
  # FIXME Verificar necessidade (não foi testado)
  validates_presence_of     :metro_area,                 :if => Proc.new { |user| user.state }
  validates_uniqueness_of   :login, :email, :case_sensitive => false
  validates_exclusion_of    :login, :in => Redu::Application.config.extras["reserved_logins"]
  validates :birthday,
      :date => { :before => Proc.new { 13.years.ago } }
  validates_acceptance_of :tos
  validates_attachment_size :curriculum, :less_than => 10.megabytes
  validate :accepted_curriculum_type, :on => :update,
    :unless => "self.curriculum_file_name.nil?"
  validates_confirmation_of :email
  validates_format_of :email,
    :with => /^([^@\s]+)@((?:[-a-z0-9A-Z]+\.)+[a-zA-Z]{2,})$/
  validates_format_of :mobile,
      :with => /^\+(\(?\d{2}\)?)?\s?\((\(?\d{2}\)?)\)?\s(\d{4}-?\d{4})/,
      :allow_blank => true

  # override activerecord's find to allow us to find by name or id transparently
  def self.find(*args)
    if args.is_a?(Array) and args.first.is_a?(String) and (args.first.index(/[a-zA-Z\-_]+/) or args.first.to_i.eql?(0) )
      find_by_login(args)
    else
      super
    end
  end

  def self.find_by_login_or_email(login)
    User.find_by_login(login) || User.find_by_email(login)
  end

  # FIXME Relacionado com featured, verificar necessidade.
  def self.find_featured
    self.featured
  end

  # Authenticates a user by their login name and unencrypted password.  Returns the user or nil.
  def self.authenticate(login, password)
    # hide records with a nil activated_at
    u = find :first, :conditions => ['login = ?', login]
    u = find :first, :conditions => ['email = ?', login] if u.nil?
    u && u.authenticated?(password) && u.update_last_login ? u : nil
  end

  def self.encrypt(password, salt)
    Digest::SHA1.hexdigest("--#{salt}--#{password}--")
  end

  # FIXME Verificar necessidade (não foi testado)
  def self.currently_online
    User.where("sb_last_seen_at > ?", Time.now.utc-5.minutes)
  end

  # FIXME Verificar necessidade (não foi testado)
  def self.search(query, options = {})
    with_scope :find => { :conditions => build_search_conditions(query) } do
      find :all, options
    end
  end

  # FIXME Verificar necessidade (não foi testado)
  def self.build_search_conditions(query)
    query
  end

  ## Instance Methods
  def profile_complete?
    (self.first_name and self.last_name and self.gender and
        self.description and self.tags) ? true : false
  end

  def can_manage?(entity)
    entity.nil? and return false
    self.admin? and return true
    self.environment_admin? entity and return true

    case entity.class.to_s
    when 'Course'
      (self.environment_admin? entity.environment)
    when 'Space'
      self.teacher?(entity) || self.can_manage?(entity.course) || self.teacher?(entity.course)
    when 'Subject'
      self.teacher?(entity.space) || self.can_manage?(entity.space)
    when 'Lecture'
      self.teacher?(entity.subject.space) || self.can_manage?(entity.subject)
    when 'Exam'
      self.teacher?(entity.subject.space) || self.can_manage?(entity.space)
    when 'Event'
      self.teacher?(entity.eventable) || self.tutor?(entity.eventable) || self.can_manage?(entity.eventable)
    when 'Bulletin'
      case entity.bulletinable.class.to_s
      when 'Environment'
        self.environment_admin?(entity.bulletinable)
      when 'Space'
        self.teacher?(entity.bulletinable) || self.tutor?(entity.bulletinable) ||
          self.can_manage?(entity.bulletinable)
      end
    when 'Folder'
      self.teacher?(entity.space) || self.tutor?(entity.space) || self.can_manage?(entity.space)
    when 'Topic'
      self.member?(entity.space)
    when 'SbPost'
      self.member?(entity.space)
    when 'Status'
      if self == entity.user
        true
      else
        case entity.statusable.class.to_s
        when 'Space'
          self.teacher?(entity.statusable) ||
            self.can_manage?(entity.statusable)
        when 'Subject'
          self.teacher?(entity.statusable.space) ||
            self.can_manage?(entity.statusable.space)
        when 'Lecture'
          self.can_manage?(entity.statusable.subject)
        end
      end
    when 'User'
      entity == self
    when 'Plan'
      entity.user == self
    when 'Invoice'
      self.can_manage?(entity.plan)
    when 'Myfile'
      self.can_manage?(entity.folder)
    when 'Friendship'
      # user_id necessário devido ao bug do create_time_zone
      self.id == entity.user_id
    end
  end

  def has_access_to?(entity)
    self.admin? and return true

    if self.get_association_with(entity)
      # Apenas Course tem state
      if entity.class.to_s == 'Course' &&
        !self.get_association_with(entity).approved?
        return false
      else
        return true
      end
    else
      case entity.class.to_s
      when 'Event'
        self.get_association_with(entity.eventable).nil? ? false : true
      when 'Bulletin'
        self.get_association_with(entity.bulletinable).nil? ? false : true
      when 'Forum'
        self.get_association_with(entity.space).nil? ? false : true
      when 'Topic'
        self.get_association_with(entity.forum.space).nil? ? false : true
      when 'SbPost'
        self.get_association_with(entity.topic.forum.space).nil? ? false : true
      when 'Folder'
        self.get_association_with(entity.space).nil? ? false : true
      when 'Status'
        unless entity.statusable.class.to_s.eql?("User")
          self.has_access_to? entity.statusable
        else
          self.friends?(entity.statusable) || self == entity.statusable
        end
      when 'Lecture'
        self.has_access_to? entity.subject
      when 'Exam'
        self.has_access_to? entity.subject
      else
        return false
      end
    end
  end

  def enrolled?(subject)
    self.get_association_with(subject).nil? ? false : true
  end

  # Método de alto nível, verifica se o object está publicado (caso se aplique)
  # e se o usuário possui acesso (i.e. relacionamento) com o mesmo
  def can_read?(object)
    if (object.class.to_s.eql? 'Folder') || (object.class.to_s.eql? 'Forum') ||
       (object.class.to_s.eql? 'Topic') || (object.class.to_s.eql? 'SbPost') ||
       (object.class.to_s.eql? 'Event') || (object.class.to_s.eql? 'Bulletin') ||
       (object.class.to_s.eql? 'Status') || (object.class.to_s.eql? 'User') ||
       (object.class.to_s.eql? 'Friendship') || (object.class.to_s.eql? 'Plan') ||
       (object.class.to_s.eql? 'Invoice')

       self.has_access_to?(object)
    else
      if (object.class.to_s.eql? 'Subject')
        object.visible? && self.has_access_to?(object)
      else
        object.published? && self.has_access_to?(object)
      end
    end
  end

  # FIXME Verificar necessidade (não foi testado)
  def can_be_owner?(entity)
    self.admin? || self.space_admin?(entity.id) || self.teacher?(entity) || self.coordinator?(entity)
  end

  # FIXME Verificar necessidade (não foi testado)
  def moderator_of?(forum)
    moderatorships.where('forum_id = ?', (forum.is_a?(Forum) ? forum.id : forum)).count == 1
  end

  # FIXME Verificar necessidade (não foi testado)
  def monitoring_topic?(topic)
    monitored_topics.find_by_id(topic.id)
  end

  # FIXME Criar teste ao definir lógica dos Redu points.
  def earn_points(activity)
    thepoints = AppConfig.points[activity]
    self.update_attribute(:score, self.score + thepoints)
  end

  # FIXME Verificar necessidade (não foi testado)
  def to_xml(options = {})
    options[:except] ||= []
    super
  end

  # FIXME Verificar necessidade (não foi testado)
  def recount_metro_area_users
    return unless self.metro_area
    ma = self.metro_area
    ma.users_count = User.where( "metro_area_id = ?", ma.id ).count
    ma.save
  end

  def to_param
    login
  end

  def this_months_posts
    self.posts.where("published_at > ?", DateTime.now.to_time.at_beginning_of_month).all
  end

  def last_months_posts
    self.posts.where("published_at > ? and published_at < ?",
                      DateTime.now.to_time.at_beginning_of_month.months_ago(1),
                      DateTime.now.to_time.at_beginning_of_month).all
  end

  # FIXME Falar com Guila
  def avatar_photo_url(size = nil)
    if avatar
      avatar.public_filename(size)
    else
      case size
      when :thumb
        AppConfig.photo['missing_thumb']
      else
        AppConfig.photo['missing_medium']
      end
    end
  end

  def deactivate
    return if admin? #don't allow admin deactivation
    @activated = false
    update_attributes(:activated_at => nil, :activation_code => make_activation_code)
  end

  def activate
    @activated = true
    update_attributes(:activated_at => Time.now.utc, :activation_code => nil)
  end

  # Indica se o usuário ainda pode utilizar o Redu sem ter ativado a conta
  def can_activate?
    activated_at.nil? and created_at > 30.days.ago
  end

  def active?
    #FIXME Workaround para quando o active? é chamado e o usuário não exite
    # (authlogic)
    return false unless created_at
    ( activated_at.nil? and (created_at < (Time.now - 30.days))) ? false : true
    # activation_code.nil? && !activated_at.nil?
    # self.activated_at
  end

  def recently_activated?
    @activated
  end

  def encrypt(password)
    self.class.encrypt(password, self.password_salt)
  end

  def authenticated?(password)
    crypted_password == encrypt(password)
  end

  # FIXME Verificar necessidade (não foi testado)
  # remember_token_expires_at não existe no BD.
  def remember_token?
    remember_token_expires_at && Time.now.utc < remember_token_expires_at
  end

  # FIXME Verificar necessidade (não foi testado)
  # remember_token_expires_at e remember_token não existem no BD.
  # These create and unset the fields required for remembering users between browser closes
  def remember_me
    self.remember_token_expires_at = 2.weeks.from_now.utc
    self.remember_token            = encrypt("#{email}--#{remember_token_expires_at}")
    save(false)
  end

  # FIXME Verificar necessidade (não foi testado)
  # remember_token_expires_at e remember_token não existem no BD.
  def forget_me
    self.remember_token_expires_at = nil
    self.remember_token            = nil
    save(false)
  end

  # FIXME Verificar necessidade (não foi testado)
  def valid_invite_code?(code)
    code == invite_code
  end

  def invite_code
    Digest::SHA1.hexdigest("#{self.id}--#{self.email}--#{self.password_salt}")
  end

  # FIXME Verificar necessidade (não foi testado)
  def location
    metro_area && metro_area.name || ""
  end

  # FIXME Verificar necessidade (não foi testado)
  def full_location
    "#{metro_area.name if self.metro_area}#{" , #{self.country.name}" if self.country}"
  end

  def reset_password
    new_password = newpass(8)
    self.password = new_password
    self.password_confirmation = new_password
    return self.valid?
  end


  def owner
    self
  end

  def staff?
    featured_writer?
  end

  # FIXME Verificar necessidade (não foi testado)
  # A tabela Frienship não existe
  def can_request_friendship_with(user)
    !self.eql?(user) && !self.friendship_exists_with?(user)
  end

  # FIXME Verificar necessidade (não foi testado)
  # A tabela Frienship não existe
  def friendship_exists_with?(friend)
    Friendship.where("user_id = ? AND friend_id = ?", self.id, friend.id).first
  end

  def update_last_login
    self.update_attribute(:last_login_at, Time.now)
  end

  # FIXME Verificar necessidade (não foi testado)
  def add_offerings(skills)
    skills.each do |skill_id|
      offering = Offering.new(:skill_id => skill_id)
      offering.user = self
      if self.under_offering_limit? && !self.has_skill?(offering.skill)
        if offering.save
          self.offerings << offering
        end
      end
    end
  end

  # FIXME Verificar necessidade (não foi testado)
  def under_offering_limit?
    self.offerings.size < 3
  end

  # FIXME Verificar necessidade (não foi testado)
  def has_skill?(skill)
    self.offerings.collect{|o| o.skill }.include?(skill)
  end

  # FIXME Verificar necessidade (não foi testado)
  # A tabela Frienship não existe
  def has_reached_daily_friend_request_limit?
    friendships_initiated_by_me.where('created_at > ?', Time.now.beginning_of_day).count >= Friendship.daily_request_limit
  end

  # FIXME Verificar necessidade (não foi testado)
  def friends_ids
    return [] if accepted_friendships.empty?
    accepted_friendships.map{|fr| fr.friend_id }
  end

  def recommended_posts(since = 1.week.ago)
    return [] if tags.empty?
    rec_posts = Post.find_tagged_with(tags.map(&:name),
                                      :conditions => ['posts.user_id != ? AND published_at > ?', self.id, since ],
                                      :order => 'published_at DESC',
                                      :limit => 10)

    if rec_posts.empty?
      []
    else
      rec_posts.uniq
    end
  end

  def display_name
    if self.removed?
      return '(usuário removido)'
    end

    if self.first_name and self.last_name
      self.first_name + " " + self.last_name
    else
      login
    end

  end

  def f_name
    if self.first_name
      self.first_name
    else
      login
    end
  end

  # FIXME Não foi testado
  # space roles
  def can_post?(space)
    if not self.get_association_with(space)
      return false
    end

    if space.submission_type == 1 or space.submission_type == 2 # all
      return true
    elsif space.submission_type == 3 #teachers and admin
      user_role = self.get_association_with(space).role
      if user_role.eql?(Role[:teacher]) or user_role.eql?(Role[:space_admin])
        return true
      else
        return false
      end
    end

  end

  # Pega associação com Entity (aplica-se a Environment, Course, Space e Subject)
  def get_association_with(entity)
    return false unless entity

    case entity.class.to_s
    when 'Space'
      association = UserSpaceAssociation.where('user_id = ? AND space_id = ?',
                                                 self.id, entity.id).first
    when 'Course'
      association = UserCourseAssociation.where('user_id = ? AND course_id = ?',
                                                  self.id, entity.id).first
    when 'Environment'
      association = UserEnvironmentAssociation.
                      where('user_id = ? AND environment_id = ?', self.id,
                              entity.id).first
    when 'Subject'
      association = Enrollment.where('user_id = ? AND subject_id = ?', self.id,
                                       entity.id).first
    end
  end

  def environment_admin?(entity)
    association = get_association_with entity
    association && association.role && association.role.eql?(Role[:environment_admin])
  end

  def admin?
    role && role.eql?(Role[:admin])
  end

  def teacher?(entity)
    association = get_association_with entity
    return false if association.nil?
    association && association.role && association.role.eql?(Role[:teacher])
  end

  def tutor?(entity)
    association = get_association_with entity
    return false if association.nil?
    association && association.role && association.role.eql?(Role[:tutor])
  end

  def member?(entity)
    association = get_association_with entity
    return false if association.nil?
    association && association.role && association.role.eql?(Role[:member])
  end

  def male?
    gender && gender.eql?(MALE)
  end

  def female?
    gender && gender.eql?(FEMALE)
  end

  # FIXME Não foi testado devido a futura reformulação de Status
  def learning
    self.statuses.log_action_eq(LEARNING_ACTIONS).descend_by_created_at
  end

  # FIXME Não foi testado devido a futura reformulação de Status
  def teaching
    self.statuses.log_action_eq(TEACHING_ACTIONS).descend_by_created_at
  end

  def profile_activity(page = 1)
    Status.profile_activity(self).
      paginate(:page => page, :order => 'created_at DESC',
               :per_page => Redu::Application.config.items_per_page)
  end

  # FIXME Não foi testado devido a futura reformulação de Status
  def home_activity(page = 1)
    Status.home_activity(self).paginate(:page => page,
                                        :order => 'created_at DESC',
                                        :per_page => Redu::Application.config.items_per_page)
  end

  def add_favorite(favoritable_type, favoritable_id)
    Favorite.create(:favoritable_type => favoritable_type,
                    :favoritable_id => favoritable_id,
                    :user_id => self.id)
  end

  def rm_favorite(favoritable_type, favoritable_id)
    fav = Favorite.where(:favoritable_type => favoritable_type,
                           :favoritable_id => favoritable_id,
                           :user_id => self.id).first
    fav.destroy
  end

    def has_favorite(favoritable)
    Favorite.where("favoritable_id = ? AND favoritable_type = ? AND user_id = ?",
                     favoritable.id, favoritable.class.to_s,self.id).first
  end

  def update_last_seen_at
    User.update_all ['sb_last_seen_at = ?', Time.now.utc], ['id = ?', self.id]
    self.sb_last_seen_at = Time.now.utc
  end

  def profile_for(subject)
    self.student_profiles.where(:subject_id => subject)
  end

  def completeness
    total = 11.0
    undone = 0.0
    undone += 1 if self.description.nil?
    undone += 1 if self.avatar_file_name.nil?
    undone += 1 if self.gender.nil?
    undone += 1 if self.curriculum_file_name.nil?
    undone += 1 if self.localization.to_s.empty?
    undone += 1 if self.mobile.to_s.empty?

    done = total - undone
    (done/total*100).round
  end

  # True se o usuário possui convite
  def has_course_invitation?(course = nil)
    UserCourseAssociation.has_invitation_for?(self, course)
  end

  def email_confirmation
    @email_confirmation || self.email
  end

  def create_settings!
    self.settings = UserSetting.create(:view_mural => Privacy[:friends])
  end

  def presence_channel
    "presence-user-#{self.id}"
  end

  def private_channel_with(user)
    if self.id < user.id
      "private-#{self.id}-#{user.id}"
    else
      "private-#{user.id}-#{self.id}"
    end
  end

  protected
  def activate_before_save
    self.activated_at = Time.now.utc
    self.activation_code = nil
  end

  def make_activation_code
    self.activation_code = Digest::SHA1.hexdigest( Time.now.to_s.split(//).sort_by {rand}.join )
  end

  # before filters
  def encrypt_password
    return if password.blank?
    self.salt = Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{login}--") if new_record?
    self.crypted_password = encrypt(password)
  end

  def password_required?
    crypted_password.blank? || !password.blank?
  end

  def accepted_curriculum_type
    unless SUPPORTED_CURRICULUM_TYPES.include?(self.curriculum_content_type)
      self.errors.add(:curriculum, "Formato inválido")
    end
  end

  def newpass( len )
    chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
    new_password = ""
    1.upto(len) { |i| new_password << chars[rand(chars.size-1)] }
    return new_password
  end

end
