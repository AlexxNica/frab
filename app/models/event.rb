# frozen_string_literal: true
class Event < ApplicationRecord
  include ActionView::Helpers::TextHelper
  include EventState

  before_create :generate_guid

  TYPES = %i(lecture workshop podium lightning_talk meeting film concert djset performance other).freeze
  ACCEPTED = %w(accepting unconfirmed confirmed scheduled).freeze

  has_one :ticket, as: :object, dependent: :destroy
  has_many :conflicts_as_conflicting, class_name: 'Conflict', foreign_key: 'conflicting_event_id', dependent: :destroy
  has_many :conflicts, dependent: :destroy
  has_many :event_attachments, dependent: :destroy
  has_many :event_feedbacks, dependent: :destroy
  has_many :event_people, dependent: :destroy
  has_many :event_ratings, dependent: :destroy
  has_many :links, as: :linkable, dependent: :destroy
  has_many :people, through: :event_people
  has_many :videos, dependent: :destroy

  belongs_to :conference
  belongs_to :track
  belongs_to :room

  has_attached_file :logo,
    styles: { tiny: '16x16>', small: '32x32>', large: '128x128>' },
    default_url: 'event_:style.png'

  accepts_nested_attributes_for :event_people, allow_destroy: true, reject_if: proc { |attr| attr[:person_id].blank? }
  accepts_nested_attributes_for :links, allow_destroy: true, reject_if: :all_blank
  accepts_nested_attributes_for :event_attachments, allow_destroy: true, reject_if: :all_blank
  accepts_nested_attributes_for :ticket, allow_destroy: true, reject_if: :all_blank

  validates_attachment_content_type :logo, content_type: [/jpg/, /jpeg/, /png/, /gif/]

  validates :title, :time_slots, presence: true

  after_save :update_conflicts

  scope :accepted, -> { where(arel_table[:state].in(ACCEPTED)) }
  scope :associated_with, ->(person) { joins(:event_people).where("event_people.person_id": person.id) }
  scope :candidates, -> { where(state: %w(new review accepting unconfirmed confirmed scheduled)) }
  scope :confirmed, -> { where(state: %w(confirmed scheduled)) }
  scope :no_conflicts, -> { includes(:conflicts).where("conflicts.event_id": nil) }
  scope :is_public, -> { where(public: true) }
  scope :scheduled_on, ->(day) { where(arel_table[:start_time].gteq(day.start_date.to_datetime)).where(arel_table[:start_time].lteq(day.end_date.to_datetime)).where(arel_table[:room_id].not_eq(nil)) }
  scope :scheduled, -> { where(arel_table[:start_time].not_eq(nil).and(arel_table[:room_id].not_eq(nil))) }
  scope :unscheduled, -> { where(arel_table[:start_time].eq(nil).or(arel_table[:room_id].eq(nil))) }
  scope :without_speaker, -> { where('speaker_count = 0') }
  scope :with_speaker, -> { where('speaker_count > 0') }
  scope :with_more_than_one_speaker, -> { where('speaker_count > 1') }

  has_paper_trail

  def self.ids_by_least_reviewed(conference, reviewer)
    already_reviewed = connection.select_rows("SELECT events.id FROM events JOIN event_ratings ON events.id = event_ratings.event_id WHERE events.conference_id = #{conference.id} AND event_ratings.person_id = #{reviewer.id}").flatten.map(&:to_i)
    least_reviewed = connection.select_rows("SELECT events.id FROM events LEFT OUTER JOIN event_ratings ON events.id = event_ratings.event_id WHERE events.conference_id = #{conference.id} GROUP BY events.id ORDER BY COUNT(event_ratings.id) ASC, events.id ASC").flatten.map(&:to_i)
    least_reviewed -= already_reviewed
    least_reviewed
  end

  def track_name
    track.try(:name)
  end

  def end_time
    start_time.since((time_slots * conference.timeslot_duration).minutes)
  end

  def duration_in_minutes
    (time_slots * conference.timeslot_duration).minutes
  end

  def feedback_standard_deviation
    arr = event_feedbacks.map(&:rating).reject(&:nil?)
    return if arr.count < 1

    n = arr.count
    m = arr.reduce(:+).to_f / n
    '%02.02f' % Math.sqrt(arr.inject(0) { |sum, item| sum + (item - m)**2 } / (n - 1))
  end

  def recalculate_average_feedback!
    update_attributes(average_feedback: average(:event_feedbacks))
  end

  def recalculate_average_rating!
    update_attributes(average_rating: average(:event_ratings))
  end

  def speakers
    event_people.presenter.includes(:person).all.map(&:person)
  end

  def humanized_time_str
    return '' unless start_time.present?
    I18n.localize(start_time, format: :time) + I18n.t('time.time_range_seperator') + I18n.localize(end_time, format: :time)
  end

  def to_s
    "#{model_name.human}: #{title}"
  end

  def to_sortable
    title.gsub(/[^\w]/, '').upcase
  end

  def overlap?(other_event)
    if start_time <= other_event.start_time and other_event.start_time < end_time
      true
    elsif other_event.start_time <= start_time and start_time < other_event.end_time
      true
    else
      false
    end
  end

  def accepted?
    ACCEPTED.include?(state)
  end

  def remote_ticket?
    ticket.present? and ticket.remote_ticket_id.present?
  end

  def update_conflicts
    conflicts.delete_all
    conflicts_as_conflicting.delete_all
    if accepted? and room and start_time and time_slots
      update_event_conflicts
      update_people_conflicts
    end
    conflicts
  end

  def conflict_level
    return 'fatal' if conflicts.any? { |c| c.severity == 'fatal' }
    return 'warning' if conflicts.any? { |c| c.severity == 'warning' }
    nil
  end

  def update_attributes_and_return_affected_ids(attributes)
    affected_event_ids = conflicts.map(&:conflicting_event_id)
    update_attributes(attributes)
    reload
    affected_event_ids += conflicts.map(&:conflicting_event_id)
    affected_event_ids.delete(nil)
    affected_event_ids << id
    affected_event_ids.uniq
  end

  def slug
    truncate(
      [
        conference.acronym,
        id,
        title.parameterize(separator: '_')
      ].flatten.join('-'),
      escape: false,
      length: 240,
      separator: '_',
      omission: ''
    ).to_str
  end

  def static_url
    File.join conference.program_export_base_url, "events/#{id}.html"
  end

  def logo_path(size = :large)
    logo(size) if logo.present?
  end

  def clean_event_attributes!
    self.start_time = nil
    self.state = ''
    self.note = ''
    self.tech_rider = ''
    self
  end

  def possible_start_times
    possible = {}

    # Retrieve a list of persons that are presenting this event,
    # and filter out those who don't have any availabilities configured.

    event_persons = event_people.presenter.group(:person_id, :id)
                                .select { |ep| ep.person.availabilities.any? }
    person_ids = event_persons.map(&:person_id)

    conference.days.each do |day|
      availabilities = Availability.where(person: person_ids, day: day)

      times = day.start_times_map do |time, pretty|
        # People with no availability at all are not present in person_ids.
        # Hence, if the number of availability records for this day is less
        # than the number of presenters in person_ids, we know that at least
        # one of them is not available.

        presenters_available = if availabilities.length == person_ids.length
                                 availabilities.map { |a| a.within_range?(time) }
                               else
                                 [false]
                               end

        if presenters_available.all?
          [pretty, time.to_s]
        elsif start_time == time
          # Special case: if the event is already scheduled, offer that start time
          # in the list as well, but add a warning, so that records are not accidentally
          # modified through HTML forms.

          [pretty + ' (not all presenters available!)', time.to_s]
        end
      end

      times.compact!
      possible[day.to_s] = times if times.any?
    end

    possible
  end

  private

  def generate_guid
    self.guid = SecureRandom.uuid
  end

  def average(rating_type)
    result = 0
    rating_count = 0
    send(rating_type).each do |rating|
      if rating.rating
        result += rating.rating
        rating_count += 1
      end
    end
    if rating_count == 0
      return nil
    else
      return result.to_f / rating_count
    end
  end

  # check if room has been assigned multiple times for the same slot
  def update_event_conflicts
    conflicting_event_candidates =
      self.class.accepted
          .where(room_id: room.id)
          .where(self.class.arel_table[:start_time].gteq(start_time.beginning_of_day))
          .where(self.class.arel_table[:start_time].lteq(start_time.end_of_day))
          .where(self.class.arel_table[:id].not_eq(id))

    conflicting_event_candidates.each do |conflicting_event|
      if overlap?(conflicting_event)
        Conflict.create(event: self, conflicting_event: conflicting_event, conflict_type: 'events_overlap', severity: 'fatal')
        Conflict.create(event: conflicting_event, conflicting_event: self, conflict_type: 'events_overlap', severity: 'fatal')
      end
    end
  end

  # check wether person has availability and is available at scheduled time
  def update_people_conflicts
    event_people.presenter.group(:person_id, :id).each do |event_person|
      next if conflict_person_has_no_availabilities(event_person)
      conflict_person_not_available(event_person)
    end
  end

  def conflict_person_has_no_availabilities(event_person)
    return if event_person.person.availabilities.present?
    Conflict.create(event: self, person: event_person.person, conflict_type: 'person_has_no_availability', severity: 'warning')
  end

  def conflict_person_not_available(event_person)
    return if event_person.available_between?(start_time, end_time)
    Conflict.create(event: self, person: event_person.person, conflict_type: 'person_unavailable', severity: 'warning')
  end
end
