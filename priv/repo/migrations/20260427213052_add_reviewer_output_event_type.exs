defmodule KiroCockpit.Repo.Migrations.AddReviewerOutputEventType do
  use Ecto.Migration

  def up do
    # Drop old constraint and recreate with reviewer_output added
    drop constraint(:plan_events, :plan_events_event_type_check)

    create constraint(:plan_events, :plan_events_event_type_check,
             check:
               "event_type IN ('created', 'revised', 'approved', 'rejected', 'running', 'completed', 'failed', 'superseded', 'reviewer_output')"
           )
  end

  def down do
    drop constraint(:plan_events, :plan_events_event_type_check)

    create constraint(:plan_events, :plan_events_event_type_check,
             check:
               "event_type IN ('created', 'revised', 'approved', 'rejected', 'running', 'completed', 'failed', 'superseded')"
           )
  end
end
