import "@hotwired/turbo-rails";
import { Application } from "@hotwired/stimulus";
import AutoscrollController from "./controllers/autoscroll_controller";
import ComposerController from "./controllers/composer_controller";
import StickyDetailsController from "./controllers/sticky_details_controller";

const application = Application.start();
application.register("autoscroll", AutoscrollController);
application.register("composer", ComposerController);
application.register("sticky-details", StickyDetailsController);
window.RbrunStimulus = application;
