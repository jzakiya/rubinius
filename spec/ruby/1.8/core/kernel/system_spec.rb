require File.dirname(__FILE__) + '/../../spec_helper'
require File.dirname(__FILE__) + '/fixtures/classes'

describe "Kernel#system" do
  it "is a private method" do
    Kernel.private_instance_methods.should include("system")
  end
end
