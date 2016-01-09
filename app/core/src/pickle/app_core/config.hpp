#line 2 "pickle/app_core/config.hpp"
/**
@copyright MIT license; see @ref index or the accompanying LICENSE file.

@file
@brief Core configuration.
@ingroup app_core_config

@defgroup app_core_config Configuration
@ingroup app_core
@details
*/

#pragma once

#include <togo/core/config.hpp>

namespace pickle {

/**
	@addtogroup app_core_config
	@{
*/

#if !defined(PICKLE_DEBUG) && (defined(DEBUG) || !defined(NDEBUG))
	#define PICKLE_DEBUG
#endif

using namespace togo;

/** @} */ // end of doc-group app_core_config

} // namespace pickle
