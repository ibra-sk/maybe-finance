class DepositoriesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :overdraft_limit
end
