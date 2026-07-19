import "@hotwired/turbo-rails";
import { Application } from "@hotwired/stimulus";
import AutoscrollController from "./controllers/autoscroll_controller";
import ComposerController from "./controllers/composer_controller";
import StickyDetailsController from "./controllers/sticky_details_controller";
import DropdownController from "./controllers/dropdown_controller";
import MenuController from "./controllers/menu_controller";

const application = Application.start();
application.register("autoscroll", AutoscrollController);
application.register("composer", ComposerController);
application.register("sticky-details", StickyDetailsController);
application.register("dropdown", DropdownController);
application.register("menu", MenuController);
window.RbrunStimulus = application;
